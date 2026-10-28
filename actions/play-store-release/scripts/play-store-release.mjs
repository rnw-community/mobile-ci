import { createPrivateKey, sign } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';

const API = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications';
const SCOPE = 'https://www.googleapis.com/auth/androidpublisher';
const MAX_ATTEMPTS = 4;

class ReleaseError extends Error {}

const fail = message => {
    throw new ReleaseError(message);
};

const readServiceAccount = path => {
    let account;
    try {
        account = JSON.parse(readFileSync(path, 'utf8'));
    } catch (error) {
        fail(`service-account-key-path '${path}' is not a readable JSON service account key: ${error.message}`);
    }
    if (typeof account?.client_email !== 'string' || typeof account?.private_key !== 'string') {
        fail(`service-account-key-path '${path}' has no client_email/private_key; pass the Google Play service account JSON key.`);
    }
    let key;
    try {
        key = createPrivateKey(account.private_key);
    } catch (error) {
        fail(`the service account private_key is not a valid RSA key: ${error.message}`);
    }
    return { email: account.client_email, key, tokenUri: account.token_uri ?? 'https://oauth2.googleapis.com/token' };
};

const readInputs = env => {
    const inputs = {
        packageName: env.PACKAGE_NAME ?? '',
        fromTrack: env.FROM_TRACK ?? '',
        toTrack: env.TO_TRACK ?? '',
        versionCode: env.VERSION_CODE ?? '',
        rollout: env.ROLLOUT ?? '',
        releaseNotesFromSource: env.RELEASE_NOTES_FROM_SOURCE ?? '',
        dryRun: env.DRY_RUN ?? '',
        keyPath: env.SERVICE_ACCOUNT_KEY_PATH ?? '',
    };
    if (!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(inputs.packageName)) {
        fail(`package-name '${inputs.packageName}' must be an Android application id such as com.example.app.`);
    }
    for (const [name, value] of [['from-track', inputs.fromTrack], ['to-track', inputs.toTrack]]) {
        if (!/^[A-Za-z0-9:_-]+$/.test(value)) {
            fail(`${name} '${value}' must be a Play track id such as internal, alpha, beta or production.`);
        }
    }
    if (inputs.fromTrack === inputs.toTrack) {
        fail(`from-track and to-track are both '${inputs.fromTrack}'; a promotion needs two different tracks.`);
    }
    if (inputs.versionCode !== '' && !/^[1-9]\d*$/.test(inputs.versionCode)) {
        fail(`version-code '${inputs.versionCode}' must be a positive integer, or empty for the highest on from-track.`);
    }
    const rollout = /^\d+(\.\d+)?$/.test(inputs.rollout) ? Number(inputs.rollout) : Number.NaN;
    if (!(rollout > 0 && rollout <= 1)) {
        fail(`rollout '${inputs.rollout}' must be a fraction in (0, 1]: 1 completes the release, anything lower is a staged rollout.`);
    }
    for (const [name, value] of [['release-notes-from-source', inputs.releaseNotesFromSource], ['dry-run', inputs.dryRun]]) {
        if (value !== 'true' && value !== 'false') {
            fail(`${name} must be 'true' or 'false', got '${value}'.`);
        }
    }
    if (inputs.keyPath === '') {
        fail('service-account-key-path is empty; pass the Google Play service account JSON key file.');
    }
    return {
        ...inputs,
        rollout,
        releaseNotesFromSource: inputs.releaseNotesFromSource === 'true',
        dryRun: inputs.dryRun === 'true',
        account: readServiceAccount(inputs.keyPath),
    };
};

const describeError = body => {
    const error = body?.error;
    if (typeof error === 'object' && error !== null) {
        return [error.status, error.message].filter(Boolean).join(': ');
    }
    return [error, body?.error_description].filter(Boolean).join(': ') || JSON.stringify(body ?? null).slice(0, 2000);
};

const send = async (method, url, init, label) => {
    for (let attempt = 1; ; attempt += 1) {
        let response;
        try {
            response = await fetch(url, { method, ...init, signal: AbortSignal.timeout(60_000) });
        } catch (error) {
            if (attempt >= MAX_ATTEMPTS) {
                fail(`${label} '${method} ${url}' failed after ${attempt} attempts: ${error.message}`);
            }
            console.log(`::warning::${label} '${method} ${url}' failed (${error.message}); retry ${attempt}/${MAX_ATTEMPTS - 1}.`);
            await new Promise(resolve => setTimeout(resolve, attempt * 10_000));
            continue;
        }
        const retriable = response.status === 429 || (method === 'GET' && response.status >= 500);
        if (retriable && attempt < MAX_ATTEMPTS) {
            console.log(`::warning::${label} '${method} ${url}' returned HTTP ${response.status}; retry ${attempt}/${MAX_ATTEMPTS - 1}.`);
            await new Promise(resolve => setTimeout(resolve, attempt * 10_000));
            continue;
        }
        const text = await response.text();
        let json = null;
        try {
            json = text === '' ? null : JSON.parse(text);
        } catch {
            json = { error: text.slice(0, 2000) };
        }
        if (response.status < 200 || response.status > 299) {
            fail(`${label} '${method} ${url}' returned HTTP ${response.status}: ${describeError(json)}`);
        }
        return json;
    }
};

const accessToken = async account => {
    const now = Math.floor(Date.now() / 1000);
    const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
    const payload = Buffer.from(
        JSON.stringify({ iss: account.email, scope: SCOPE, aud: account.tokenUri, iat: now, exp: now + 3600 }),
    ).toString('base64url');
    const signature = sign('sha256', Buffer.from(`${header}.${payload}`), account.key).toString('base64url');
    const body = new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: `${header}.${payload}.${signature}`,
    });
    const response = await send(
        'POST',
        account.tokenUri,
        { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: body.toString() },
        'Google OAuth',
    );
    return response?.access_token ?? fail('the Google OAuth token response carried no access_token.');
};

const percent = fraction => `${Math.round(fraction * 10000) / 100}%`;

const releaseCodes = release => (release.versionCodes ?? []).map(Number);

const run = async () => {
    const inputs = readInputs(process.env);
    const token = await accessToken(inputs.account);
    const base = `${API}/${encodeURIComponent(inputs.packageName)}/edits`;
    const play = (method, path, body) =>
        send(
            method,
            `${base}${path}`,
            {
                headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
                ...(body !== undefined && { body: JSON.stringify(body) }),
            },
            'Google Play',
        );
    const rows = [];

    const edit = (await play('POST', '')) ?? {};
    if (typeof edit.id !== 'string') {
        fail('Google Play returned no edit id.');
    }
    let committed = false;
    try {
        const source = (await play('GET', `/${edit.id}/tracks/${encodeURIComponent(inputs.fromTrack)}`)) ?? {};
        const candidates = (source.releases ?? []).filter(release => releaseCodes(release).length > 0);
        const versionCode =
            inputs.versionCode !== ''
                ? Number(inputs.versionCode)
                : Math.max(...candidates.flatMap(releaseCodes), Number.NEGATIVE_INFINITY);
        if (!Number.isFinite(versionCode)) {
            fail(`track '${inputs.fromTrack}' of ${inputs.packageName} has no release with a version code to promote.`);
        }
        const sourceRelease =
            candidates.find(release => releaseCodes(release).includes(versionCode)) ??
            fail(`version code ${versionCode} is not on track '${inputs.fromTrack}' of ${inputs.packageName}; only a build already on from-track can be promoted.`);
        rows.push(['Resolve version code', `${versionCode} on ${inputs.fromTrack} (${sourceRelease.name ?? 'unnamed'}, ${sourceRelease.status})`, 'resolved']);

        const target = (await play('GET', `/${edit.id}/tracks/${encodeURIComponent(inputs.toTrack)}`)) ?? {};
        const status = inputs.rollout === 1 ? 'completed' : 'inProgress';
        const existing = (target.releases ?? []).find(release => releaseCodes(release).includes(versionCode));
        const unchanged =
            existing !== undefined &&
            (existing.status === 'completed' || (existing.status === status && Number(existing.userFraction) === inputs.rollout));
        const rolloutLabel = status === 'completed' ? 'completed (100%)' : `inProgress (${percent(inputs.rollout)})`;
        if (unchanged) {
            rows.push([`Promote to ${inputs.toTrack}`, `${versionCode} is already ${existing.status}${existing.userFraction ? ` at ${percent(existing.userFraction)}` : ''}`, 'unchanged']);
            return { inputs, rows, versionCode, result: 'already-released' };
        }

        const release = {
            ...(sourceRelease.name && { name: sourceRelease.name }),
            versionCodes: [String(versionCode)],
            status,
            ...(status === 'inProgress' && { userFraction: inputs.rollout }),
            ...(inputs.releaseNotesFromSource && sourceRelease.releaseNotes && { releaseNotes: sourceRelease.releaseNotes }),
        };
        const notes = inputs.releaseNotesFromSource ? `${sourceRelease.releaseNotes?.length ?? 0} release-note language(s) copied` : 'no release notes';
        if (inputs.dryRun) {
            rows.push([`Promote to ${inputs.toTrack}`, `${versionCode}, ${rolloutLabel}, ${notes}`, 'would do']);
            return { inputs, rows, versionCode, result: 'planned' };
        }
        await play('PUT', `/${edit.id}/tracks/${encodeURIComponent(inputs.toTrack)}`, { track: inputs.toTrack, releases: [release] });
        await play('POST', `/${edit.id}:commit`);
        committed = true;
        rows.push([`Promote to ${inputs.toTrack}`, `${versionCode}, ${rolloutLabel}, ${notes}`, 'done']);
        return { inputs, rows, versionCode, result: 'released' };
    } finally {
        if (!committed) {
            await play('DELETE', `/${edit.id}`).catch(error => console.log(`::warning::could not discard Play edit ${edit.id}: ${error.message}`));
        }
    }
};

const writeReport = report => {
    const { inputs } = report;
    const title = `### Google Play release${inputs.dryRun ? ' (dry run: nothing was changed)' : ''}`;
    const subject = `${inputs.packageName} ${report.versionCode}: ${inputs.fromTrack} -> ${inputs.toTrack} - ${report.result}`;
    const table = ['| Step | Detail | Status |', '| --- | --- | --- |', ...report.rows.map(row => `| ${row.join(' | ')} |`)];
    for (const row of report.rows) {
        console.log(`${row[2].padEnd(10)} ${row[0]}: ${row[1]}`);
    }
    if (process.env.GITHUB_STEP_SUMMARY) {
        appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${[title, '', subject, '', ...table].join('\n')}\n`);
    }
    if (process.env.GITHUB_OUTPUT) {
        appendFileSync(process.env.GITHUB_OUTPUT, `version-code=${report.versionCode}\nresult=${report.result}\n`);
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
