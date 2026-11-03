import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';

import { transferSlots } from '../src/transfers.ts';

const dir = () => mkdtempSync(join(tmpdir(), 'e2e-simlock-slots-'));
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

/** Runs `count` transfers through `gates` (round robin) and reports the most that were ever in flight together. */
async function peak(gates: ((work: () => Promise<void>) => Promise<void>)[], count: number): Promise<number> {
    let active = 0;
    let most = 0;
    await Promise.all(
        Array.from({ length: count }, (_, i) =>
            gates[i % gates.length]!(async () => {
                active += 1;
                most = Math.max(most, active);
                await sleep(30);
                active -= 1;
            })
        )
    );
    return most;
}

describe('transferSlots', () => {
    it('never lets more than `limit` transfers run at once, across gates sharing the directory (the workers)', async () => {
        const shared = dir();
        const gates = Array.from({ length: 4 }, () => transferSlots(shared, 2, 5));
        assert.equal(await peak(gates, 12), 2);
        assert.deepEqual(readdirSync(shared), [], 'every slot is released');
    });

    it('holds a slot across processes: a transfer waits while another process holds the only slot', async () => {
        const shared = dir();
        // A separate Node process takes the one slot for 400 ms.
        const holder = spawn(process.execPath, [
            '--input-type=module',
            '-e',
            `import { transferSlots } from ${JSON.stringify(new URL('../src/transfers.ts', import.meta.url).href)};
             await transferSlots(${JSON.stringify(shared)}, 1, 5)(async () => { console.log('held'); await new Promise(r => setTimeout(r, 400)); });`
        ]);
        await new Promise<void>(resolve => holder.stdout.once('data', () => resolve()));
        const started = Date.now();
        await transferSlots(shared, 1, 5)(async () => undefined);
        assert.ok(Date.now() - started >= 250, `waited ${Date.now() - started} ms for the other process`);
        await new Promise(resolve => holder.once('exit', resolve));
    });

    it('frees the slot when the transfer fails', async () => {
        const shared = dir();
        const gate = transferSlots(shared, 1, 5);
        await assert.rejects(gate(async () => Promise.reject(new Error('524'))), { message: '524' });
        assert.equal(await gate(async () => 'next'), 'next');
    });

    it('reclaims a slot whose holder died without releasing it', async () => {
        const shared = dir();
        writeFileSync(join(shared, 'slot-0.lock'), '999999999');
        assert.equal(await transferSlots(shared, 1, 5)(async () => 'ran'), 'ran');
        assert.equal(existsSync(join(shared, 'slot-0.lock')), false);
    });

    it('refuses a limit that is not a whole number of at least 1', () => {
        assert.throws(() => transferSlots(dir(), 0), { message: 'transferSlots: limit must be a whole number of at least 1; got 0' });
    });
});
