import { createPrivateKey, sign } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';

const API = 'https://api.appstoreconnect.apple.com/v1';
const MAX_ATTEMPTS = 4;
const RELEASE_TYPES = new Set(['MANUAL', 'AFTER_APPROVAL', 'SCHEDULED']);
const EDITABLE_STATES = [
    'PREPARE_FOR_SUBMISSION',
    'READY_FOR_REVIEW',
    'DEVELOPER_REJECTED',
    'REJECTED',
    'METADATA_REJECTED',
    'INVALID_BINARY',
];
const REUSABLE_SUBMISSION_STATES = ['READY_FOR_REVIEW', 'UNRESOLVED_ISSUES'];

class ReleaseError extends Error {}

const fail = message => {
    throw new ReleaseError(message);
};

const readInputs = env => {
    const inputs = {
        appId: env.APP_ID ?? '',
        version: env.VERSION ?? '',
        buildNumber: env.BUILD_NUMBER ?? '',
        releaseType: env.RELEASE_TYPE ?? '',
        scheduledReleaseDate: env.SCHEDULED_RELEASE_DATE ?? '',
        phasedRelease: env.PHASED_RELEASE ?? '',
        dryRun: env.DRY_RUN ?? '',
        keyPath: env.ASC_KEY_PATH ?? '',
        keyId: env.ASC_KEY_ID ?? '',
        issuerId: env.ASC_ISSUER_ID ?? '',
    };
    if (!/^\d+$/.test(inputs.appId)) {
        fail(`app-id '${inputs.appId}' must be the numeric App Store Connect app id (App Information > Apple ID).`);
    }
    if (!/^\d+(\.\d+){0,2}$/.test(inputs.version)) {
        fail(`version '${inputs.version}' must be a marketing version such as 1.2.3.`);
    }
    if (inputs.buildNumber !== '' && !/^\d+(\.\d+){0,2}$/.test(inputs.buildNumber)) {
        fail(`build-number '${inputs.buildNumber}' must be a CFBundleVersion such as 42 or 1.2.3, or empty.`);
    }
    if (!RELEASE_TYPES.has(inputs.releaseType)) {
        fail(`release-type '${inputs.releaseType}' must be MANUAL, AFTER_APPROVAL or SCHEDULED.`);
    }
    if (inputs.releaseType === 'SCHEDULED') {
        if (Number.isNaN(Date.parse(inputs.scheduledReleaseDate))) {
            fail(`release-type SCHEDULED needs scheduled-release-date as an ISO-8601 date-time, got '${inputs.scheduledReleaseDate}'.`);
        }
    } else if (inputs.scheduledReleaseDate !== '') {
        fail('scheduled-release-date is only valid with release-type SCHEDULED.');
    }
    for (const [name, value] of [['phased-release', inputs.phasedRelease], ['dry-run', inputs.dryRun]]) {
        if (value !== 'true' && value !== 'false') {
            fail(`${name} must be 'true' or 'false', got '${value}'.`);
        }
    }
    if (inputs.keyPath === '') {
        fail('asc-key-path is empty; pass the App Store Connect API key (.p8) file.');
    }
    if (!/^[A-Za-z0-9]+$/.test(inputs.keyId)) {
        fail('asc-key-id must be a non-empty alphanumeric App Store Connect key ID.');
    }
    if (!/^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/.test(inputs.issuerId)) {
        fail('asc-issuer-id must be a UUID.');
    }
    let key;
    try {
        key = createPrivateKey(readFileSync(inputs.keyPath, 'utf8'));
    } catch (error) {
        fail(`asc-key-path '${inputs.keyPath}' is not a readable EC private key (.p8): ${error.message}`);
    }
    return {
        ...inputs,
        key,
        phasedRelease: inputs.phasedRelease === 'true',
        dryRun: inputs.dryRun === 'true',
        scheduledReleaseDate: inputs.releaseType === 'SCHEDULED' ? new Date(inputs.scheduledReleaseDate).toISOString() : null,
    };
};

const describeErrors = body => {
    const lines = [];
    const visit = (errors, prefix) => {
        for (const error of errors ?? []) {
            const pointer = error.source?.pointer ? ` (${error.source.pointer})` : '';
            lines.push(`${prefix}${[error.code, error.title, error.detail].filter(Boolean).join(': ')}${pointer}`);
            for (const [path, nested] of Object.entries(error.meta?.associatedErrors ?? {})) {
                visit(nested, `${prefix}${path}: `);
            }
        }
    };
    visit(body?.errors, '');
    return lines.length > 0 ? lines : [JSON.stringify(body ?? null).slice(0, 2000)];
};

const createClient = inputs => {
    const token = () => {
        const now = Math.floor(Date.now() / 1000);
        const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: inputs.keyId, typ: 'JWT' })).toString('base64url');
        const payload = Buffer.from(
            JSON.stringify({ iss: inputs.issuerId, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' }),
        ).toString('base64url');
        const signature = sign('sha256', Buffer.from(`${header}.${payload}`), { key: inputs.key, dsaEncoding: 'ieee-p1363' });
        return `${header}.${payload}.${signature.toString('base64url')}`;
    };

    const send = async (method, path, body) => {
        for (let attempt = 1; ; attempt += 1) {
            let response;
            try {
                response = await fetch(`${API}${path}`, {
                    method,
                    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
                    ...(body !== undefined && { body: JSON.stringify(body) }),
                    signal: AbortSignal.timeout(60_000),
                });
            } catch (error) {
                if (attempt >= MAX_ATTEMPTS) {
                    fail(`App Store Connect '${method} ${path}' failed after ${attempt} attempts: ${error.message}`);
                }
                console.log(`::warning::App Store Connect '${method} ${path}' failed (${error.message}); retry ${attempt}/${MAX_ATTEMPTS - 1}.`);
                await new Promise(resolve => setTimeout(resolve, attempt * 10_000));
                continue;
            }
            const retriable = response.status === 429 || (method === 'GET' && response.status >= 500);
            if (retriable && attempt < MAX_ATTEMPTS) {
                console.log(`::warning::App Store Connect '${method} ${path}' returned HTTP ${response.status}; retry ${attempt}/${MAX_ATTEMPTS - 1}.`);
                await new Promise(resolve => setTimeout(resolve, attempt * 10_000));
                continue;
            }
            const text = await response.text();
            let json = null;
            try {
                json = text === '' ? null : JSON.parse(text);
            } catch {
                json = { raw: text.slice(0, 2000) };
            }
            if (response.status === 404 && method === 'GET') {
                return null;
            }
            if (response.status < 200 || response.status > 299) {
                const details = describeErrors(json).map(line => `  ${line}`).join('\n');
                fail(`App Store Connect '${method} ${path}' returned HTTP ${response.status}:\n${details}`);
            }
            return json;
        }
    };

    return {
        get: path => send('GET', path),
        mutate: (method, path, body) => send(method, path, body),
    };
};

const query = (path, params) => `${path}?${new URLSearchParams(params)}`;

const versionState = version => version.attributes.appVersionState ?? version.attributes.appStoreState;

const resolveBuild = async (client, inputs) => {
    const params = {
        'filter[app]': inputs.appId,
        'filter[preReleaseVersion.version]': inputs.version,
        'filter[preReleaseVersion.platform]': 'IOS',
        sort: '-uploadedDate',
        limit: '1',
    };
    if (inputs.buildNumber !== '') {
        const builds = (await client.get(query('/builds', { ...params, 'filter[version]': inputs.buildNumber })))?.data ?? [];
        const build = builds[0] ?? fail(`build ${inputs.buildNumber} of version ${inputs.version} was not found on App Store Connect.`);
        if (build.attributes.processingState !== 'VALID') {
            fail(`build ${inputs.buildNumber} of version ${inputs.version} is ${build.attributes.processingState}, not VALID; wait for processing to finish or pick another build.`);
        }
        return build;
    }
    const builds = (await client.get(query('/builds', { ...params, 'filter[processingState]': 'VALID', 'filter[expired]': 'false' })))?.data ?? [];
    return builds[0] ?? fail(`no VALID, unexpired build of version ${inputs.version} exists on App Store Connect; upload one or wait for processing to finish.`);
};

const run = async () => {
    const inputs = readInputs(process.env);
    const client = createClient(inputs);
    const rows = [];
    const step = async (what, detail, mutation) => {
        if (inputs.dryRun) {
            rows.push([what, detail, 'would do']);
            return null;
        }
        const result = await mutation();
        rows.push([what, detail, 'done']);
        return result;
    };

    const app = (await client.get(`/apps/${inputs.appId}`))?.data ?? fail(`App Store Connect app ${inputs.appId} was not found, or this API key cannot see it.`);
    const build = await resolveBuild(client, inputs);
    const buildNumber = build.attributes.version;
    rows.push(['Resolve build', `${inputs.version} (${buildNumber})`, 'resolved']);

    const findVersions = async params =>
        (await client.get(query(`/apps/${inputs.appId}/appStoreVersions`, { 'filter[platform]': 'IOS', limit: '1', ...params })))?.data ?? [];
    const [sameVersion] = await findVersions({ 'filter[versionString]': inputs.version });
    let version = sameVersion ?? null;
    let attachedBuildId = null;
    if (version !== null) {
        attachedBuildId = (await client.get(`/appStoreVersions/${version.id}/build`))?.data?.id ?? null;
        const state = versionState(version);
        if (!EDITABLE_STATES.includes(state)) {
            if (attachedBuildId === build.id) {
                rows.push(['App Store version', `${inputs.version} is already ${state} with build ${buildNumber}`, 'unchanged']);
                return { inputs, rows, buildNumber, result: 'already-submitted', app };
            }
            fail(`version ${inputs.version} is ${state}${attachedBuildId === null ? ' with no build' : ' with another build'}, not build ${buildNumber}; App Store Connect only changes the build of an editable version. Remove it from review (or ship a new version) first.`);
        }
        rows.push(['App Store version', `${inputs.version} (${state})`, 'found']);
    }

    if (build.attributes.usesNonExemptEncryption === null || build.attributes.usesNonExemptEncryption === undefined) {
        fail(`build ${buildNumber} has no export compliance answer (usesNonExemptEncryption is unset). Set ITSAppUsesNonExemptEncryption in Info.plist (expo: ios.config.usesNonExemptEncryption) or answer it for this build in App Store Connect, then re-run.`);
    }

    const releaseAttributes = {
        releaseType: inputs.releaseType,
        ...(inputs.scheduledReleaseDate !== null && { earliestReleaseDate: inputs.scheduledReleaseDate }),
    };
    if (version === null) {
        const [editable] = await findVersions({ 'filter[appVersionState]': EDITABLE_STATES.join(',') });
        if (editable) {
            version = editable;
            attachedBuildId = (await client.get(`/appStoreVersions/${version.id}/build`))?.data?.id ?? null;
            await step('Rename editable version', `${editable.attributes.versionString} -> ${inputs.version}, ${inputs.releaseType}`, () =>
                client.mutate('PATCH', `/appStoreVersions/${version.id}`, {
                    data: { type: 'appStoreVersions', id: version.id, attributes: { versionString: inputs.version, ...releaseAttributes } },
                }),
            );
        } else {
            const created = await step('Create App Store version', `${inputs.version}, ${inputs.releaseType}`, () =>
                client.mutate('POST', '/appStoreVersions', {
                    data: {
                        type: 'appStoreVersions',
                        attributes: { platform: 'IOS', versionString: inputs.version, ...releaseAttributes },
                        relationships: { app: { data: { type: 'apps', id: inputs.appId } } },
                    },
                }),
            );
            version = created?.data ?? null;
        }
    } else if (
        version.attributes.releaseType !== inputs.releaseType ||
        (inputs.scheduledReleaseDate !== null && Date.parse(version.attributes.earliestReleaseDate ?? '') !== Date.parse(inputs.scheduledReleaseDate))
    ) {
        await step('Set release type', inputs.releaseType, () =>
            client.mutate('PATCH', `/appStoreVersions/${version.id}`, {
                data: { type: 'appStoreVersions', id: version.id, attributes: releaseAttributes },
            }),
        );
    }

    if (attachedBuildId === build.id) {
        rows.push(['Attach build', buildNumber, 'unchanged']);
    } else {
        await step('Attach build', buildNumber, () =>
            client.mutate('PATCH', `/appStoreVersions/${version.id}/relationships/build`, { data: { type: 'builds', id: build.id } }),
        );
    }

    const phased = version === null ? null : ((await client.get(`/appStoreVersions/${version.id}/appStoreVersionPhasedRelease`))?.data ?? null);
    if (inputs.phasedRelease && phased === null) {
        await step('Phased release', 'enable (7-day rollout)', () =>
            client.mutate('POST', '/appStoreVersionPhasedReleases', {
                data: {
                    type: 'appStoreVersionPhasedReleases',
                    attributes: { phasedReleaseState: 'INACTIVE' },
                    relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } },
                },
            }),
        );
    } else if (!inputs.phasedRelease && phased !== null) {
        await step('Phased release', 'disable', () => client.mutate('DELETE', `/appStoreVersionPhasedReleases/${phased.id}`));
    } else {
        rows.push(['Phased release', inputs.phasedRelease ? 'enabled' : 'disabled', 'unchanged']);
    }

    const [draft] =
        (
            await client.get(
                query('/reviewSubmissions', {
                    'filter[app]': inputs.appId,
                    'filter[platform]': 'IOS',
                    'filter[state]': REUSABLE_SUBMISSION_STATES.join(','),
                    limit: '1',
                }),
            )
        )?.data ?? [];
    let submission = draft ?? null;
    if (submission === null) {
        submission = (
            await step('Create review submission', 'IOS', () =>
                client.mutate('POST', '/reviewSubmissions', {
                    data: {
                        type: 'reviewSubmissions',
                        attributes: { platform: 'IOS' },
                        relationships: { app: { data: { type: 'apps', id: inputs.appId } } },
                    },
                }),
            )
        )?.data ?? null;
    } else {
        rows.push(['Review submission', `${submission.id} (${submission.attributes.state})`, 'found']);
    }

    const items =
        submission === null ? [] : ((await client.get(query(`/reviewSubmissions/${submission.id}/items`, { include: 'appStoreVersion', limit: '50' })))?.data ?? []);
    if (items.some(item => item.relationships?.appStoreVersion?.data?.id === version?.id)) {
        rows.push(['Add version to submission', inputs.version, 'unchanged']);
    } else {
        await step('Add version to submission', inputs.version, () =>
            client.mutate('POST', '/reviewSubmissionItems', {
                data: {
                    type: 'reviewSubmissionItems',
                    relationships: {
                        reviewSubmission: { data: { type: 'reviewSubmissions', id: submission.id } },
                        appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } },
                    },
                },
            }),
        );
    }

    await step('Submit for App Review', `${inputs.version} (${buildNumber})`, () =>
        client.mutate('PATCH', `/reviewSubmissions/${submission.id}`, {
            data: { type: 'reviewSubmissions', id: submission.id, attributes: { submitted: true } },
        }),
    );

    return { inputs, rows, buildNumber, result: inputs.dryRun ? 'planned' : 'submitted', app };
};

const writeReport = report => {
    const { inputs } = report;
    const title = `### App Store release${inputs.dryRun ? ' (dry run: nothing was changed)' : ''}`;
    const subject = `${report.app.attributes?.bundleId ?? inputs.appId} ${inputs.version} (${report.buildNumber}) - ${report.result}`;
    const table = ['| Step | Detail | Status |', '| --- | --- | --- |', ...report.rows.map(row => `| ${row.join(' | ')} |`)];
    for (const row of report.rows) {
        console.log(`${row[2].padEnd(10)} ${row[0]}: ${row[1]}`);
    }
    if (process.env.GITHUB_STEP_SUMMARY) {
        appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${[title, '', subject, '', ...table].join('\n')}\n`);
    }
    if (process.env.GITHUB_OUTPUT) {
        appendFileSync(process.env.GITHUB_OUTPUT, `version=${inputs.version}\nbuild-number=${report.buildNumber}\nresult=${report.result}\n`);
    }
};

try {
    writeReport(await run());
} catch (error) {
    const lines = error instanceof ReleaseError ? error.message.split('\n') : [String(error?.stack ?? error)];
    for (const line of lines) {
        console.log(`::error::${line}`);
    }
    process.exitCode = 1;
}
