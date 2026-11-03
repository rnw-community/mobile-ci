import { randomBytes } from 'node:crypto';

import { allocateQueued, FARM_DOWN, freeDevices, limiter, recordLease, type Platform } from './farm.ts';
import { startBootRelay, type BootRelay } from './relay.ts';

import type { DeviceLease, DeviceProvider, DeviceRequest } from '@e2e-dev/mobile';
import type { createAgentDeviceClient } from 'agent-device';

/** Where the farm answers, what to lease from it, and how the run treats the lease. */
export interface SimlockOptions {
    /** The simlock gateway or worker, without `/v1`: `https://simlock.example.com`. */
    readonly url: string;
    /** The simlock agent token the run leases with. */
    readonly token: string;
    readonly platform: Platform;
    /** A model the farm's catalog lists (`GET /v1/catalog?platform=…`): `iPhone 17 Pro`, `Pixel 6`. */
    readonly device: string;
    /** OS version (Android API level, iOS runtime) to lease; the farm's default for the model when omitted. */
    readonly osVersion?: string;
    /** Android system image tag, e.g. `aosp_atd` or `google_apis`; the farm's choice when omitted. */
    readonly imageTag?: string;
    /** Apps (`.app` or `.apk`) installed on every leased device after the app under test. */
    readonly extraApps?: readonly string[];
    /** Lease TTL, renewed every third of it. Short, so a run killed before it releases frees its device within one TTL. Default 3 min. */
    readonly ttlMs?: number;
    /** App uploads in flight at once: each carries the app through the gateway, and a tunnel request past 100 s ends in a 524. Default 3. */
    readonly installConcurrency?: number;
    /** How long a slot may wait for the farm to have a device free before the run fails. Default 20 min. */
    readonly queueMs?: number;
    /** simlock tenant the leases are filed under; name your project. Default `mobile-ci-e2e`. */
    readonly tenant?: string;
}

type ClientFactory = typeof createAgentDeviceClient;
type Client = ReturnType<ClientFactory>;

interface Scope {
    readonly tenant: string;
    readonly runId: string;
    readonly leaseId: string;
    readonly leaseBackend: `${Platform}-instance`;
    readonly leaseProvider: 'proxy';
    readonly clientId: string;
    readonly deviceKey?: string;
}

interface Held extends DeviceLease {
    readonly stop: () => void;
    readonly scope: Scope;
}

/** A leased device that could not be set up (an app install failed): another device may well succeed. */
export class DeviceSetupFailed extends Error {}

const positive = (name: string, value: number | undefined, fallback: number): number => {
    if (value === undefined) {
        return fallback;
    }
    if (!Number.isFinite(value) || value <= 0) {
        throw new Error(`simlockDevices: ${name} must be a positive number; got ${String(value)}`);
    }
    return value;
};

function validated(options: SimlockOptions) {
    if (!/^https?:\/\/[^/]/.test(options.url ?? '')) {
        throw new Error(`simlockDevices: url must be an http(s) URL of the simlock gateway or worker; got ${JSON.stringify(options.url)}`);
    }
    if (!options.token) {
        throw new Error('simlockDevices: token is required (the simlock agent token, e.g. process.env.SIMLOCK_TOKEN)');
    }
    if (options.platform !== 'ios' && options.platform !== 'android') {
        throw new Error(`simlockDevices: platform must be 'ios' or 'android'; got ${JSON.stringify(options.platform)}`);
    }
    if (!options.device) {
        throw new Error('simlockDevices: device is required (a model from the farm catalog)');
    }
    return {
        baseUrl: `${options.url.replace(/\/$/, '')}/v1/agent-device`,
        ttlMs: positive('ttlMs', options.ttlMs, 3 * 60_000),
        installConcurrency: Math.floor(positive('installConcurrency', options.installConcurrency, 3)),
        queueMs: positive('queueMs', options.queueMs, 20 * 60_000),
        tenant: options.tenant || 'mobile-ci-e2e'
    };
}

/**
 * A `DeviceProvider` for `@e2e-dev/mobile` that leases one iOS simulator or Android emulator per
 * worker slot from a simlock farm through its agent-device proxy (`/v1/agent-device`). The run
 * drives the device from this machine, Linux included; the app is uploaded, not copied to the
 * farm. Each slot holds its own short lease, renewed while held, recorded in
 * `.e2e/simlock-leases.json`, and released at the end of the run, when simlock wipes the device.
 */
export function simlockDevices(options: SimlockOptions): DeviceProvider {
    return createProvider(options, async () => (await import('agent-device')).createAgentDeviceClient);
}

/** `simlockDevices` with the agent-device client injected; for tests. */
export function createProvider(options: SimlockOptions, loadClient: () => Promise<ClientFactory>): DeviceProvider {
    const { baseUrl, ttlMs, installConcurrency, queueMs, tenant } = validated(options);
    const { platform, device, token } = options;
    const leaseBackend = `${platform}-instance` as const;
    const held = new Map<string, Held>();
    const uploads = limiter(installConcurrency);
    let relay: Promise<BootRelay> | undefined;

    const client = async (session: string, scope?: Scope): Promise<Client> =>
        (await loadClient())({ daemonBaseUrl: baseUrl, daemonAuthToken: token, session, ...scope });

    const startRelay = (): Promise<BootRelay> => {
        relay ??= startBootRelay(baseUrl).catch((cause: unknown) => {
            relay = undefined;
            throw cause;
        });
        return relay;
    };

    const leaseOnce = async (request: DeviceRequest, attempt: number): Promise<DeviceLease> => {
        const session = `e2e-${request.runId.slice(0, 12)}-${request.slot}${attempt === 0 ? '' : `-r${attempt}`}`;
        const started = Date.now();
        const base = { tenant, runId: request.runId, leaseBackend, leaseProvider: 'proxy' as const, clientId: randomBytes(8).toString('hex') };
        const c = await client(session);
        const lease = await allocateQueued({
            platform,
            allocate: leaseId =>
                c.leases.allocate({
                    ...base,
                    leaseId,
                    ttlMs,
                    platform,
                    target: 'mobile',
                    device,
                    ...(options.osVersion === undefined ? {} : { osVersion: options.osVersion }),
                    ...(options.imageTag === undefined ? {} : { imageTag: options.imageTag })
                }),
            release: leaseId => c.leases.release({ ...base, leaseId }),
            free: () => freeDevices(options.url, token, platform),
            log: request.log,
            signal: request.signal,
            queueMs
        });
        const scope: Scope = {
            ...base,
            leaseId: lease.leaseId,
            clientId: lease.clientId ?? base.clientId,
            ...(lease.deviceKey === undefined ? {} : { deviceKey: lease.deviceKey })
        };
        // A simulator by UDID (`ios:mobile:<udid>`), an emulator by adb serial (`android:mobile:<serial>`):
        // the proxy lists every device the token holds, so each command names the leased one.
        const deviceId = lease.deviceKey?.split(':').pop() || undefined;
        recordLease(request.projectRoot, lease.leaseId);
        request.log(`simlock lease ${lease.leaseId} granted in ${Date.now() - started} ms (${device} ${deviceId ?? 'no device id'})`);
        let missed = 0;
        const timer = setInterval(
            () => {
                c.leases
                    .heartbeat({ ...scope, ttlMs })
                    .then(() => {
                        missed = 0;
                    })
                    .catch((cause: unknown) => {
                        missed += 1;
                        request.log(
                            missed >= 2
                                ? `simlock lease ${lease.leaseId} missed ${missed} heartbeats: it may have expired, and failures on its device are infrastructure, not tests (${String(cause)})`
                                : `simlock heartbeat failed: ${String(cause)}`
                        );
                    });
            },
            Math.max(10_000, Math.floor(ttlMs / 3))
        );
        timer.unref();
        try {
            if (deviceId === undefined) {
                throw new Error(`simlock lease ${lease.leaseId} names no device (deviceKey ${String(lease.deviceKey)})`);
            }
            request.signal.throwIfAborted();
            const selection = platform === 'android' ? { serial: deviceId } : { udid: deviceId };
            const scoped = await client(session, scope);
            const install = async (appPath: string, app?: string): Promise<void> => {
                try {
                    await uploads(() => scoped.apps.install({ platform, ...selection, appPath, ...(app === undefined ? {} : { app }) }));
                } catch (cause) {
                    throw new DeviceSetupFailed(`${cause instanceof Error ? cause.message : String(cause)} (${deviceId})`, { cause });
                }
            };
            if (request.appPath !== undefined) {
                const installStarted = Date.now();
                await install(request.appPath, request.app);
                request.log(`simlock uploaded and installed ${request.app ?? request.appPath} in ${Date.now() - installStarted} ms`);
            }
            for (const extra of options.extraApps ?? []) {
                await install(extra);
            }
            const entry: Held = {
                id: lease.leaseId,
                daemon: { baseUrl: (await startRelay()).baseUrl, authToken: token },
                client: scope,
                deviceId,
                ...(request.appPath === undefined || request.app === undefined ? {} : { installedApp: request.app }),
                stop: () => clearInterval(timer),
                scope
            };
            held.set(entry.id, entry);
            return entry;
        } catch (cause) {
            // The engine releases only leases acquire returned: hand this one back now, not one TTL later.
            clearInterval(timer);
            await c.leases.release(scope).catch((cleanup: unknown) => request.log(`simlock release after a failed acquire failed: ${String(cleanup)}`));
            throw cause;
        }
    };

    return {
        name: 'simlock',
        async acquire(request: DeviceRequest): Promise<DeviceLease> {
            if (request.platform !== platform) {
                throw new Error(`simlockDevices leases ${platform} devices; the target asked for ${request.platform}`);
            }
            try {
                return await leaseOnce(request, 0);
            } catch (cause) {
                // One bad device must not fail the run: its lease is already released, so lease another,
                // once. A farm that is down fails every slot at once, and a swap would only add load.
                if (!(cause instanceof DeviceSetupFailed) || FARM_DOWN.test(cause.message)) {
                    throw cause;
                }
                request.signal.throwIfAborted();
                request.log(`simlock: ${cause.message}; leasing another device`);
                return leaseOnce(request, 1);
            }
        },
        async release(lease: DeviceLease, context): Promise<void> {
            const entry = held.get(lease.id);
            if (entry === undefined) {
                return;
            }
            entry.stop();
            try {
                const c = await client(`release-${lease.id.slice(0, 8)}`);
                await c.leases.release({ ...entry.scope, signal: context.signal });
            } finally {
                // A failed release still frees this process: the farm reclaims the lease after one TTL.
                held.delete(lease.id);
                if (held.size === 0 && relay !== undefined) {
                    const closing = relay;
                    relay = undefined;
                    await (await closing).close();
                }
            }
        }
    };
}
