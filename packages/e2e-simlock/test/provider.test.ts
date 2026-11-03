import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, it, mock } from 'node:test';

import { createProvider, simlockDevices, type SimlockOptions } from '../src/provider.ts';

import type { DeviceLease, DeviceRequest } from '@e2e-dev/mobile';

type Params = Record<string, unknown>;

/** A fake agent-device client: each allocate grants the next device key, and installs fail as scripted. */
function fakeFarm(deviceKeys: (string | undefined)[], installErrors: (string | undefined)[] = []) {
    const calls = { allocate: [] as Params[], install: [] as Params[], release: [] as Params[], heartbeat: [] as Params[], sessions: [] as string[], allocateUrls: [] as string[], otherUrls: [] as string[] };
    let releaseError: Error | undefined;
    let heartbeatError: Error | undefined;
    const factory = (config: Params) => {
        calls.sessions.push(String(config.session));
        const url = String(config.daemonBaseUrl);
        return {
            leases: {
                allocate: async (params: Params) => {
                    calls.allocate.push(params);
                    calls.allocateUrls.push(url);
                    const deviceKey = deviceKeys.shift();
                    return { leaseId: params.leaseId, clientId: params.clientId, ...(deviceKey === undefined ? {} : { deviceKey }) };
                },
                heartbeat: async (params: Params) => {
                    calls.heartbeat.push(params);
                    calls.otherUrls.push(url);
                    if (heartbeatError) throw heartbeatError;
                },
                release: async (params: Params) => {
                    calls.release.push(params);
                    calls.otherUrls.push(url);
                    if (releaseError) throw releaseError;
                }
            },
            apps: {
                install: async (params: Params) => {
                    calls.install.push(params);
                    const error = installErrors.shift();
                    if (error !== undefined) throw new Error(error);
                }
            }
        };
    };
    return {
        calls,
        load: async () => factory as never,
        failRelease: (error: Error) => (releaseError = error),
        failHeartbeat: (error: Error) => (heartbeatError = error)
    };
}

const android: SimlockOptions = { url: 'https://farm.test', token: 'tok', platform: 'android', device: 'Pixel 6', osVersion: '34', imageTag: 'aosp_atd', tenant: 'suuudokuuu' };
const ios: SimlockOptions = { url: 'https://farm.test/', token: 'tok', platform: 'ios', device: 'iPhone 17 Pro' };

function request(platform: 'ios' | 'android', overrides: Partial<DeviceRequest> = {}) {
    const logs: string[] = [];
    const req: DeviceRequest = {
        platform,
        runId: 'run-0123456789abcdef',
        targetName: platform,
        slot: 0,
        slots: 1,
        agentDeviceVersion: '0.21.36',
        app: 'com.example.app',
        appPath: platform === 'android' ? '/build/app.apk' : '/build/App.app',
        projectRoot: mkdtempSync(join(tmpdir(), 'e2e-simlock-')),
        env: {},
        signal: new AbortController().signal,
        log: line => logs.push(line),
        ...overrides
    };
    return { req, logs };
}

const releaseContext = { runId: 'r', targetName: 't', env: {}, signal: new AbortController().signal, log: () => undefined };

const relayAnswers = async (lease: DeviceLease): Promise<boolean> =>
    fetch(`${lease.daemon!.baseUrl}/rpc`, { method: 'POST', body: JSON.stringify({ id: 1, params: { command: 'boot', flags: { serial: 's' } } }) }).then(
        r => r.ok,
        () => false
    );

let realFetch: typeof fetch;
beforeEach(() => {
    realFetch = globalThis.fetch;
    // The farm reports no free count: every slot asks at once. The relay check above uses Node's own fetch.
    globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) =>
        String(input).startsWith('https://farm.test') ? new Response('', { status: 503 }) : realFetch(input, init)) as typeof fetch;
});
afterEach(() => {
    globalThis.fetch = realFetch;
    mock.timers.reset();
});

describe('simlockDevices options', () => {
    it('fails closed on every malformed option, naming it', () => {
        const cases: [Partial<SimlockOptions>, string][] = [
            [{ url: 'farm.test' }, 'simlockDevices: url must be an http(s) URL of the simlock gateway or worker; got "farm.test"'],
            [{ token: '' }, 'simlockDevices: token is required (the simlock agent token, e.g. process.env.SIMLOCK_TOKEN)'],
            [{ platform: 'tvos' as never }, `simlockDevices: platform must be 'ios' or 'android'; got "tvos"`],
            [{ device: '' }, 'simlockDevices: device is required (a model from the farm catalog)'],
            [{ ttlMs: 0 }, 'simlockDevices: ttlMs must be a positive number; got 0'],
            [{ queueMs: Number.NaN }, 'simlockDevices: queueMs must be a positive number; got NaN'],
            [{ installConcurrency: -1 }, 'simlockDevices: installConcurrency must be a positive number; got -1'],
            [{ deviceMode: 'mode-full' as never }, `simlockDevices: deviceMode must be 'slim' or 'full'; got "mode-full"`]
        ];
        for (const [override, message] of cases) {
            assert.throws(() => simlockDevices({ ...android, ...override }), { message });
        }
    });
});

describe('acquire and release', () => {
    it('leases an Android emulator from the android-instance backend and installs the APK on its serial', async () => {
        const farm = fakeFarm(['android:mobile:emulator-5586']);
        const provider = createProvider(android, farm.load);
        const { req, logs } = request('android');
        const lease = await provider.acquire(req);

        const allocate = farm.calls.allocate[0]!;
        assert.match(String(allocate.leaseId), /^[0-9a-f]{32}$/);
        assert.deepEqual({ ...allocate, leaseId: 'L', clientId: 'C' }, {
            tenant: 'suuudokuuu',
            runId: 'run-0123456789abcdef',
            leaseBackend: 'android-instance',
            leaseProvider: 'proxy',
            clientId: 'C',
            leaseId: 'L',
            ttlMs: 180_000,
            platform: 'android',
            target: 'mobile',
            device: 'Pixel 6',
            osVersion: '34',
            imageTag: 'aosp_atd'
        });
        assert.deepEqual(farm.calls.install, [{ platform: 'android', serial: 'emulator-5586', appPath: '/build/app.apk', app: 'com.example.app' }]);
        assert.equal(lease.deviceId, 'emulator-5586');
        assert.equal(lease.installedApp, 'com.example.app');
        assert.deepEqual(lease.client, {
            tenant: 'suuudokuuu',
            runId: 'run-0123456789abcdef',
            leaseBackend: 'android-instance',
            leaseProvider: 'proxy',
            clientId: allocate.clientId,
            leaseId: allocate.leaseId,
            deviceKey: 'android:mobile:emulator-5586'
        });
        assert.equal(lease.daemon?.authToken, 'tok');
        assert.match(lease.daemon!.baseUrl, /^http:\/\/127\.0\.0\.1:\d+$/);
        assert.deepEqual(JSON.parse(readFileSync(join(req.projectRoot, '.e2e', 'simlock-leases.json'), 'utf8')), [lease.id]);
        assert.match(logs[0]!, /^simlock lease [0-9a-f]{32} granted in \d+ ms \(Pixel 6 emulator-5586\)$/);
        assert.ok(await relayAnswers(lease));

        await provider.release(lease, releaseContext);
        assert.equal(farm.calls.release.length, 1);
        assert.equal(farm.calls.release[0]!.leaseId, lease.id);
        assert.equal(await relayAnswers(lease), false, 'the relay closes with the last lease');
    });

    it('leases an iOS simulator by UDID, under the default tenant, with no OS pin', async () => {
        const farm = fakeFarm(['ios:mobile:A1B2']);
        const provider = createProvider(ios, farm.load);
        const lease = await provider.acquire(request('ios').req);
        const allocate = farm.calls.allocate[0]!;
        assert.equal(allocate.tenant, 'mobile-ci-e2e');
        assert.equal(allocate.leaseBackend, 'ios-instance');
        assert.ok(!('osVersion' in allocate) && !('imageTag' in allocate));
        assert.deepEqual(farm.calls.install[0], { platform: 'ios', udid: 'A1B2', appPath: '/build/App.app', app: 'com.example.app' });
        assert.equal(lease.deviceId, 'A1B2');
        assert.equal(farm.calls.sessions[0], 'e2e-run-01234567-0');
        await provider.release(lease, releaseContext);
    });

    it('installs extra apps after the app under test, and reports no installed app without an appPath', async () => {
        const farm = fakeFarm(['ios:mobile:A1B2']);
        const provider = createProvider({ ...ios, extraApps: ['/support/E2EDrop.app'] }, farm.load);
        const lease = await provider.acquire(request('ios', { appPath: undefined }).req);
        assert.deepEqual(farm.calls.install, [{ platform: 'ios', udid: 'A1B2', appPath: '/support/E2EDrop.app' }]);
        assert.equal(lease.installedApp, undefined);
        await provider.release(lease, releaseContext);
    });

    it("queues on the farm's free count for its own platform, and fails closed at the queue deadline", async () => {
        const asked: string[] = [];
        globalThis.fetch = (async (input: string | URL | Request) => {
            asked.push(String(input));
            await new Promise(resolve => setTimeout(resolve, 5));
            return new Response(JSON.stringify({ capacity: { ios: { limit: 9, used: 0 }, android: { limit: 2, used: 2, warm: 0 } } }));
        }) as typeof fetch;
        const farm = fakeFarm(['android:mobile:e-1']);
        await assert.rejects(createProvider({ ...android, queueMs: 1 }, farm.load).acquire(request('android').req), {
            message: 'simlock: no free android device on the farm within the 0 min queue'
        });
        assert.deepEqual(asked, ['https://farm.test/v1/status']);
        assert.equal(farm.calls.allocate.length, 0);
    });

    it('sends only the allocate through the relay, which carries deviceMode; renewals and releases go to the farm', async () => {
        const farm = fakeFarm(['ios:mobile:A1B2']);
        const provider = createProvider({ ...ios, deviceMode: 'full' }, farm.load);
        const lease = await provider.acquire(request('ios').req);
        assert.deepEqual(farm.calls.allocateUrls, [lease.daemon!.baseUrl]);
        assert.ok(!('deviceMode' in farm.calls.allocate[0]!), 'the client call itself never names it: the relay puts it on the wire');
        await provider.release(lease, releaseContext);
        assert.deepEqual(farm.calls.otherUrls, ['https://farm.test/v1/agent-device']);
    });

    it('closes the relay once every acquire has failed, so nothing keeps the run alive', async () => {
        const farm = fakeFarm([undefined]);
        const provider = createProvider(android, farm.load);
        await assert.rejects(provider.acquire(request('android').req));
        const relayUrl = farm.calls.allocateUrls[0]!;
        assert.match(relayUrl, /^http:\/\/127\.0\.0\.1:\d+$/);
        await assert.rejects(realFetch(`${relayUrl}/rpc`, { method: 'POST', body: '{}' }));
    });

    it('refuses a target of the other platform', async () => {
        const provider = createProvider(android, fakeFarm([]).load);
        await assert.rejects(provider.acquire(request('ios').req), { message: 'simlockDevices leases android devices; the target asked for ios' });
    });

    it('swaps a device whose app install failed, once, after releasing it', async () => {
        const farm = fakeFarm(['android:mobile:emulator-1', 'android:mobile:emulator-2'], ['adb: INSTALL_FAILED_INSUFFICIENT_STORAGE']);
        const provider = createProvider(android, farm.load);
        const { req, logs } = request('android');
        const lease = await provider.acquire(req);
        assert.equal(lease.deviceId, 'emulator-2');
        assert.equal(farm.calls.allocate.length, 2);
        assert.equal(farm.calls.release.length, 1);
        assert.equal(farm.calls.release[0]!.deviceKey, 'android:mobile:emulator-1');
        assert.deepEqual(farm.calls.sessions.slice(0, 1), ['e2e-run-01234567-0']);
        assert.ok(farm.calls.sessions.includes('e2e-run-01234567-0-r1'));
        assert.ok(logs.includes('simlock: adb: INSTALL_FAILED_INSUFFICIENT_STORAGE (emulator-1); leasing another device'));
        await provider.release(lease, releaseContext);
    });

    it('fails after the one swap when the second device fails too, releasing both', async () => {
        const farm = fakeFarm(['android:mobile:e-1', 'android:mobile:e-2'], ['install failed', 'install failed again']);
        await assert.rejects(createProvider(android, farm.load).acquire(request('android').req), { message: 'install failed again (e-2)' });
        assert.equal(farm.calls.allocate.length, 2);
        assert.equal(farm.calls.release.length, 2);
    });

    it('never swaps when the farm itself is down', async () => {
        const farm = fakeFarm(['android:mobile:e-1', 'android:mobile:e-2'], ['Remote daemon is unavailable']);
        await assert.rejects(createProvider(android, farm.load).acquire(request('android').req), { message: 'Remote daemon is unavailable (e-1)' });
        assert.equal(farm.calls.allocate.length, 1);
        assert.equal(farm.calls.release.length, 1);
    });

    it('a grant that names no device is released at once, without a swap', async () => {
        const farm = fakeFarm([undefined]);
        await assert.rejects(createProvider(android, farm.load).acquire(request('android').req), { message: /^simlock lease [0-9a-f]{32} names no device \(deviceKey undefined\)$/ });
        assert.equal(farm.calls.allocate.length, 1);
        assert.equal(farm.calls.release.length, 1);
        assert.equal(farm.calls.install.length, 0);
    });

    it('a failed release still closes the relay, and reports the failure', async () => {
        const farm = fakeFarm(['android:mobile:e-1']);
        const provider = createProvider(android, farm.load);
        const lease = await provider.acquire(request('android').req);
        farm.failRelease(new Error('LEASE_NOT_FOUND'));
        await assert.rejects(provider.release(lease, releaseContext), { message: 'LEASE_NOT_FOUND' });
        assert.equal(await relayAnswers(lease), false);
        await provider.release(lease, releaseContext);
        assert.equal(farm.calls.release.length, 1, 'a lease is released once');
    });

    it('renews each lease every third of its TTL, and says so once heartbeats keep failing', async () => {
        mock.timers.enable({ apis: ['setInterval'] });
        const farm = fakeFarm(['android:mobile:e-1']);
        const provider = createProvider({ ...android, ttlMs: 60_000 }, farm.load);
        const { req, logs } = request('android');
        const lease = await provider.acquire(req);
        mock.timers.tick(20_000);
        await new Promise(setImmediate);
        assert.equal(farm.calls.heartbeat.length, 1);
        assert.equal(farm.calls.heartbeat[0]!.ttlMs, 60_000);
        assert.equal(farm.calls.heartbeat[0]!.leaseId, lease.id);
        farm.failHeartbeat(new Error('LEASE_EXPIRED'));
        mock.timers.tick(20_000);
        await new Promise(setImmediate);
        mock.timers.tick(20_000);
        await new Promise(setImmediate);
        assert.ok(logs.includes('simlock heartbeat failed: Error: LEASE_EXPIRED'));
        assert.ok(logs.some(line => line.startsWith(`simlock lease ${lease.id} missed 2 heartbeats`)));
        await provider.release(lease, releaseContext);
        mock.timers.tick(60_000);
        await new Promise(setImmediate);
        assert.equal(farm.calls.heartbeat.length, 3, 'a released lease is no longer renewed');
    });
});
