import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';

import { allocateQueued, FARM_DOWN, freeDevices, LEASE_CUT_OFF, limiter, pause, recordLease, type QueuedAllocation } from '../src/farm.ts';

const json = (body: unknown, status = 200): Response => new Response(JSON.stringify(body), { status });

describe('LEASE_CUT_OFF', () => {
    it('matches only the tunnel cutting off a blocked lease request', () => {
        assert.ok(LEASE_CUT_OFF.test('error code: 524'));
        assert.ok(LEASE_CUT_OFF.test('Invalid daemon response: <html>'));
        // The tunnel dropping the blocked request itself (suuudokuuu#791).
        assert.ok(LEASE_CUT_OFF.test('socket hang up'));
        assert.ok(LEASE_CUT_OFF.test('other side closed'));
        for (const other of ['error code: 502', 'error code: 522', 'LEASE_NOT_FOUND', 'fetch failed', 'refused: name --platform ios or android']) {
            assert.ok(!LEASE_CUT_OFF.test(other), other);
        }
    });
});

describe('FARM_DOWN', () => {
    it('matches farm-wide failures and not a device failure', () => {
        for (const down of ['not connected to the gateway', 'No worker connected', 'Remote daemon is unavailable', 'connect ECONNREFUSED', 'ETIMEDOUT', 'fetch failed', 'error code: 522']) {
            assert.ok(FARM_DOWN.test(down), down);
        }
        for (const device of ['adb: failed to install app.apk', 'simctl install exited 1', 'error code: 404']) {
            assert.ok(!FARM_DOWN.test(device), device);
        }
    });
});

describe('freeDevices', () => {
    const status = { capacity: { ios: { limit: 12, used: 12, warm: 1 }, android: { limit: 2, used: 2, warm: 0 } } };

    it("reads the platform's own capacity, warm devices counting as free, with the bearer token", async () => {
        const seen: { url: string; auth: string | null }[] = [];
        const fetchImpl = (async (url: string, init: RequestInit) => {
            seen.push({ url, auth: new Headers(init.headers).get('authorization') });
            return json(status);
        }) as typeof fetch;
        assert.equal(await freeDevices('https://farm.test/', 'tok', 'ios', fetchImpl), 1);
        assert.equal(await freeDevices('https://farm.test', 'tok', 'android', fetchImpl), 0);
        assert.deepEqual(seen[0], { url: 'https://farm.test/v1/status', auth: 'Bearer tok' });
    });

    it('is undefined, never an error, when the farm does not say', async () => {
        const cases: (() => Promise<Response>)[] = [
            async () => json(status, 503),
            async () => json({ capacity: { ios: { limit: 4 } } }),
            async () => json({ capacity: { android: { used: 1 } } }),
            async () => json({ capacity: { android: { limit: '2' } } }),
            async () => new Response('not json'),
            async () => {
                throw new TypeError('fetch failed');
            }
        ];
        for (const answer of cases) {
            assert.equal(await freeDevices('https://farm.test', 't', 'android', answer as typeof fetch), undefined);
        }
    });
});

/** A queue with a fake clock that advances by each pause. */
function queue<L>(overrides: Partial<QueuedAllocation<L>> & Pick<QueuedAllocation<L>, 'allocate'>) {
    let clock = 0;
    const logs: string[] = [];
    const pauses: number[] = [];
    const released: string[] = [];
    const q: QueuedAllocation<L> = {
        platform: 'android',
        release: async id => {
            released.push(id);
        },
        free: async () => undefined,
        log: line => logs.push(line),
        signal: new AbortController().signal,
        queueMs: 60_000,
        now: () => clock,
        pause: async ms => {
            pauses.push(ms);
            clock += ms;
        },
        ...overrides
    };
    return { q, logs, pauses, released, tick: (ms: number) => (clock += ms) };
}

describe('allocateQueued', () => {
    it('asks at once when the farm does not report its free count', async () => {
        const ids: string[] = [];
        const { q, pauses } = queue({ allocate: async id => (ids.push(id), 'lease') });
        assert.equal(await allocateQueued(q), 'lease');
        assert.equal(pauses.length, 0);
        assert.match(ids[0]!, /^[0-9a-f]{32}$/);
    });

    it('waits while the farm is full, logging once, then asks', async () => {
        const free = [0, 0, 1];
        const { q, logs, pauses } = queue({ free: async () => free.shift(), allocate: async () => 'lease' });
        assert.equal(await allocateQueued(q), 'lease');
        assert.equal(pauses.length, 2);
        assert.ok(pauses.every(ms => ms >= 10_000 && ms < 15_000));
        assert.deepEqual(logs, ['simlock: the farm has no free android device; waiting for one']);
    });

    it('fails closed at the queue deadline', async () => {
        const { q } = queue({ free: async () => 0, allocate: async () => assert.fail('must not ask a full farm') });
        await assert.rejects(allocateQueued(q), { message: 'simlock: no free android device on the farm within the 1 min queue' });
    });

    it('releases a cut-off request by its own id and asks again under a new one', async () => {
        const ids: string[] = [];
        const { q, released, logs } = queue({
            allocate: async id => {
                ids.push(id);
                if (ids.length === 1) {
                    throw new Error('error code: 524');
                }
                return 'lease';
            }
        });
        assert.equal(await allocateQueued(q), 'lease');
        assert.equal(ids.length, 2);
        assert.notEqual(ids[0], ids[1]);
        assert.deepEqual(released, [ids[0]]);
        assert.deepEqual(logs, ['simlock: lease request cut off while the farm was full (error code: 524); waiting to ask again']);
    });

    it('a cut-off whose release fails still asks again', async () => {
        let calls = 0;
        const { q } = queue({
            release: async () => {
                throw new Error('release failed');
            },
            allocate: async () => {
                calls += 1;
                if (calls === 1) {
                    throw new Error('Invalid daemon response');
                }
                return 'lease';
            }
        });
        assert.equal(await allocateQueued(q), 'lease');
    });

    it('fails at once on any error but the cut-off, releasing nothing', async () => {
        const refused = new Error('refused: simlock leases only plain devices');
        let calls = 0;
        const { q, released } = queue({
            allocate: async () => {
                calls += 1;
                throw refused;
            }
        });
        await assert.rejects(allocateQueued(q), refused);
        assert.equal(calls, 1);
        assert.deepEqual(released, []);
    });

    it('a cut-off past the deadline is released and rethrown', async () => {
        const cutOff = new Error('error code: 524');
        const state = queue<string>({ allocate: async () => assert.fail('replaced below') });
        const q: QueuedAllocation<string> = {
            ...state.q,
            allocate: async () => {
                state.tick(61_000);
                throw cutOff;
            }
        };
        await assert.rejects(allocateQueued(q), cutOff);
        assert.equal(state.released.length, 1);
    });

    it('stops with the abort reason, before asking and while waiting', async () => {
        const aborted = new AbortController();
        aborted.abort(new Error('interrupted'));
        const before = queue({ signal: aborted.signal, allocate: async () => assert.fail('must not ask after an abort') });
        await assert.rejects(allocateQueued(before.q), { message: 'interrupted' });

        const during = new AbortController();
        const waiting = queue({
            signal: during.signal,
            free: async () => 0,
            pause,
            allocate: async () => assert.fail('must not ask a full farm')
        });
        const run = allocateQueued(waiting.q);
        setTimeout(() => during.abort(new Error('interrupted while queued')), 20);
        await assert.rejects(run, { message: 'interrupted while queued' });
    });
});

describe('pause', () => {
    it('resolves after the delay and rejects on an abort', async () => {
        await pause(5, new AbortController().signal);
        const controller = new AbortController();
        const waiting = pause(60_000, controller.signal);
        controller.abort(new Error('stop'));
        await assert.rejects(waiting, { message: 'stop' });
    });
});

describe('limiter', () => {
    it('runs at most `limit` calls at once, and frees a slot when one fails', async () => {
        const run = limiter(2);
        let active = 0;
        let peak = 0;
        const work = (fail: boolean) => async () => {
            active += 1;
            peak = Math.max(peak, active);
            await new Promise(resolve => setTimeout(resolve, 5));
            active -= 1;
            if (fail) {
                throw new Error('upload failed');
            }
            return 'ok';
        };
        const results = await Promise.allSettled([run(work(true)), run(work(false)), run(work(false)), run(work(false))]);
        assert.equal(peak, 2);
        assert.deepEqual(
            results.map(r => r.status),
            ['rejected', 'fulfilled', 'fulfilled', 'fulfilled']
        );
    });
});

describe('recordLease', () => {
    it('keeps every lease id once, and recovers from a file that is not a list of ids', () => {
        const root = mkdtempSync(join(tmpdir(), 'e2e-simlock-'));
        const file = join(root, '.e2e', 'simlock-leases.json');
        recordLease(root, 'a');
        recordLease(root, 'b');
        recordLease(root, 'a');
        assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')), ['a', 'b']);
        writeFileSync(file, 'not json');
        recordLease(root, 'c');
        assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')), ['c']);
        mkdirSync(join(root, '.e2e'), { recursive: true });
        writeFileSync(file, JSON.stringify(['d', 42, { id: 'x' }]));
        recordLease(root, 'e');
        assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')), ['d', 'e']);
    });
});
