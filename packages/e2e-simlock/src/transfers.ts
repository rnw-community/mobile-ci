import { createHash } from 'node:crypto';
import { linkSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

/**
 * Exec payloads larger than this (an E2EDrop file or archive) take a transfer slot, like an app upload:
 * through the public tunnel a request past 100 s ends in a 524, so big transfers must not all run at once.
 */
export const LARGE_PAYLOAD_BYTES = 1024 * 1024;

const alive = (pid: number): boolean => {
    try {
        process.kill(pid, 0);
        return true;
    } catch (cause) {
        return (cause as NodeJS.ErrnoException).code === 'EPERM';
    }
};

/**
 * Takes `slot` when it is free, or held by a process that died without releasing it. The holder's pid is
 * written first and the slot then linked to it in one step, so no process ever reads a slot without its holder.
 */
function take(slot: string): boolean {
    const claim = `${slot}.${process.pid}.${Math.random().toString(36).slice(2)}`;
    writeFileSync(claim, String(process.pid));
    try {
        linkSync(claim, slot);
        return true;
    } catch (cause) {
        if ((cause as NodeJS.ErrnoException).code !== 'EEXIST') {
            throw cause;
        }
    } finally {
        rmSync(claim, { force: true });
    }
    let holder = Number.NaN;
    try {
        holder = Number(readFileSync(slot, 'utf8').trim());
    } catch {
        return take(slot);
    }
    if (Number.isInteger(holder) && holder > 0 && alive(holder)) {
        return false;
    }
    rmSync(slot, { force: true });
    return take(slot);
}

/**
 * A counting semaphore shared by every process on the machine: `limit` lock files in `dir`. The e2e
 * runner and its forked workers each run their transfers through it, so at most `limit` are in flight.
 */
export function transferSlots(dir: string, limit: number, pollMs = 250): <T>(work: () => Promise<T>) => Promise<T> {
    if (!Number.isInteger(limit) || limit < 1) {
        throw new Error(`transferSlots: limit must be a whole number of at least 1; got ${String(limit)}`);
    }
    return async work => {
        mkdirSync(dir, { recursive: true });
        let held: string | undefined;
        while (held === undefined) {
            for (let i = 0; i < limit && held === undefined; i++) {
                const slot = join(dir, `slot-${i}.lock`);
                if (take(slot)) {
                    held = slot;
                }
            }
            if (held === undefined) {
                await new Promise(resolve => setTimeout(resolve, pollMs));
            }
        }
        try {
            return await work();
        } finally {
            rmSync(held, { force: true });
        }
    };
}

const limits = new Map<string, number>();

/** The machine-wide slot directory of one farm. */
const slotsOf = (url: string): string =>
    join(tmpdir(), `mobile-ci-e2e-simlock-transfers-${createHash('sha256').update(url.replace(/\/$/, '')).digest('hex').slice(0, 16)}`);

/** Sets how many big transfers to `url` may run at once (`installConcurrency`); every process loading the config sets the same. */
export function configureTransfers(url: string, limit: number): void {
    limits.set(url.replace(/\/$/, ''), limit);
}

/** Runs one big transfer to the farm at `url` in a machine-wide slot (3 at once unless configured). */
export function transfer<T>(url: string, work: () => Promise<T>): Promise<T> {
    return transferSlots(slotsOf(url), limits.get(url.replace(/\/$/, '')) ?? 3)(work);
}
