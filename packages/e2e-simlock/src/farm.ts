import { randomBytes } from 'node:crypto';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export type Platform = 'ios' | 'android';

/**
 * A lease request the public tunnel cut off while the farm was full (a 524, or the connection dropped), or one the farm
 * granted on a warm emulator that has left adb, which it reclaims within a minute: the slot releases it, waits for a
 * device and asks again.
 */
export const LEASE_ASK_AGAIN = /Invalid daemon response|error code: 524|socket hang up|other side closed|No Android device with serial/i;

/** Errors that mean the farm, not one device, failed (simlock's gateway and agent-device wording): never worth a device swap. */
export const FARM_DOWN =
    /not connected to the gateway|no worker connected|Remote daemon is unavailable|ECONNREFUSED|ETIMEDOUT|fetch failed|error code: 52\d/i;

/** The tunnel answering an upload in place of the farm (a 524 past its 100 s limit): no install was sent, so the upload can be sent again. */
export const UPLOAD_CUT = /Invalid upload response: error code: 52\d/i;

/** How often a queued slot asks the farm for its free count: 10 s plus up to 5 s of jitter. */
const POLL_MS = 10_000;
const POLL_JITTER_MS = 5_000;

export type Pause = (ms: number, signal: AbortSignal) => Promise<void>;

/** Waits `ms`, or rejects with the signal's reason as soon as it aborts. */
export const pause: Pause = (ms, signal) =>
    new Promise((resolve, reject) => {
        if (signal.aborted) {
            reject(signal.reason);
            return;
        }
        const onAbort = (): void => {
            clearTimeout(timer);
            reject(signal.reason);
        };
        const timer = setTimeout(() => {
            signal.removeEventListener('abort', onAbort);
            resolve();
        }, ms);
        signal.addEventListener('abort', onAbort, { once: true });
    });

/**
 * The platform's free devices on the farm (`GET /v1/status`: limit minus devices leased, warm
 * ones counting as free), or undefined when the farm does not say. Never throws: an unknown
 * count lets the slot ask for a lease and get the farm's own answer.
 */
export async function freeDevices(url: string, token: string, platform: Platform, fetchImpl: typeof fetch = fetch): Promise<number | undefined> {
    try {
        const response = await fetchImpl(`${url.replace(/\/$/, '')}/v1/status`, {
            headers: { authorization: `Bearer ${token}` },
            signal: AbortSignal.timeout(15_000)
        });
        if (!response.ok) {
            return undefined;
        }
        const body = (await response.json()) as { capacity?: Partial<Record<Platform, { limit?: unknown; used?: unknown; warm?: unknown }>> };
        const { limit, used = 0, warm = 0 } = body.capacity?.[platform] ?? {};
        if (typeof limit !== 'number' || typeof used !== 'number' || typeof warm !== 'number') {
            return undefined;
        }
        return limit - (used - warm);
    } catch {
        return undefined;
    }
}

export interface QueuedAllocation<L> {
    readonly platform: Platform;
    /** Asks the farm for one lease under the given id. */
    readonly allocate: (leaseId: string) => Promise<L>;
    /** Hands back a lease by id; a failure is ignored. */
    readonly release: (leaseId: string) => Promise<unknown>;
    readonly free: () => Promise<number | undefined>;
    readonly log: (message: string) => void;
    readonly signal: AbortSignal;
    readonly queueMs: number;
    readonly now?: () => number;
    readonly pause?: Pause;
}

/**
 * `allocate`, queued client-side. A lease request blocks while the farm is full, and through the
 * public Cloudflare tunnel one open past 100 s ends in a 524, so the slot first waits for the farm
 * to report a free device. A request cut off anyway is released by its own id (the farm may still
 * grant it) and asked again, as is one naming an emulator gone from adb. Any other error fails at once; so does the queue deadline and an abort.
 */
export async function allocateQueued<L>(queue: QueuedAllocation<L>): Promise<L> {
    const now = queue.now ?? Date.now;
    const wait = queue.pause ?? pause;
    const deadline = now() + queue.queueMs;
    let waiting = false;
    for (;;) {
        queue.signal.throwIfAborted();
        const free = await queue.free();
        if (free !== undefined && free <= 0) {
            if (now() > deadline) {
                throw new Error(`simlock: no free ${queue.platform} device on the farm within the ${Math.round(queue.queueMs / 60_000)} min queue`);
            }
            if (!waiting) {
                queue.log(`simlock: the farm has no free ${queue.platform} device; waiting for one`);
                waiting = true;
            }
            await wait(POLL_MS + Math.floor(Math.random() * POLL_JITTER_MS), queue.signal);
            continue;
        }
        const leaseId = randomBytes(16).toString('hex');
        try {
            return await queue.allocate(leaseId);
        } catch (cause) {
            const message = cause instanceof Error ? cause.message : String(cause);
            if (!LEASE_ASK_AGAIN.test(message)) {
                throw cause;
            }
            await queue.release(leaseId).catch(() => undefined);
            if (now() > deadline) {
                throw cause;
            }
            queue.log(`simlock: lease request not served (${message}); waiting to ask again`);
            // A cut-off that comes back at once (a dropped socket) must not turn the queue into a busy loop.
            await wait(POLL_MS + Math.floor(Math.random() * POLL_JITTER_MS), queue.signal);
        }
    }
}

/**
 * Adds a lease id to `<projectRoot>/.e2e/simlock-leases.json`, the list mobile-ci's e2e job
 * releases in an `if: always()` step, so a run killed mid-way still frees the farm.
 */
export function recordLease(projectRoot: string, id: string): void {
    const file = join(projectRoot, '.e2e', 'simlock-leases.json');
    let ids: unknown = [];
    try {
        ids = JSON.parse(readFileSync(file, 'utf8'));
    } catch {
        ids = [];
    }
    const known = Array.isArray(ids) ? ids.filter((entry): entry is string => typeof entry === 'string') : [];
    mkdirSync(join(projectRoot, '.e2e'), { recursive: true });
    // Written whole and renamed into place, so the release step never reads a half-written list.
    const next = `${file}.${process.pid}.tmp`;
    writeFileSync(next, JSON.stringify([...new Set([...known, id])]));
    renameSync(next, file);
}
