import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, it } from 'node:test';

import { randomBytes } from 'node:crypto';

import { drop, E2E_DROP_APP, exec, leaseIdForUdid, mustExec, simlockApiFromEnv } from '../src/exec.ts';
import { configureTransfers, transfer } from '../src/transfers.ts';

import type { AddressInfo } from 'node:net';

const api = { url: 'https://farm.test/', token: 'tok' };
const sse = (...events: [string, unknown][]) => events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n`).join('\n');

let realFetch: typeof fetch;
let answers: (() => Response)[];
let requests: { url: string; init: RequestInit }[];
beforeEach(() => {
    realFetch = globalThis.fetch;
    answers = [];
    requests = [];
    globalThis.fetch = (async (input: string | URL | Request, init: RequestInit = {}) => {
        requests.push({ url: String(input), init });
        const next = answers.shift();
        assert.ok(next, `unexpected request to ${String(input)}`);
        return next();
    }) as typeof fetch;
});
afterEach(() => {
    globalThis.fetch = realFetch;
});

describe('simlockApiFromEnv', () => {
    it('reads SIMLOCK_URL and SIMLOCK_TOKEN, and fails closed without them', () => {
        assert.deepEqual(simlockApiFromEnv({ SIMLOCK_URL: 'https://farm.test', SIMLOCK_TOKEN: 't' }), { url: 'https://farm.test', token: 't' });
        assert.throws(() => simlockApiFromEnv({ SIMLOCK_URL: 'https://farm.test' }), { message: 'SIMLOCK_URL and SIMLOCK_TOKEN are required' });
    });
});

describe('exec', () => {
    it("runs simctl on the lease's simulator and collects its output and exit status", async () => {
        answers.push(() => new Response(sse(['output', { stream: 'stdout', chunk: 'a' }], ['output', { stream: 'stderr', chunk: 'warn' }], ['output', { stream: 'stdout', chunk: 'b' }], ['exit', { exitCode: 3 }])));
        assert.deepEqual(await exec(api, 'L1', ['listapps'], 'payload'), { exitCode: 3, stdout: 'ab', stderr: 'warn' });
        assert.equal(requests[0]!.url, 'https://farm.test/v1/leases/L1/exec');
        assert.deepEqual(JSON.parse(String(requests[0]!.init.body)), { tool: 'simctl', args: ['listapps'], stdin: 'payload' });
        assert.equal(new Headers(requests[0]!.init.headers).get('authorization'), 'Bearer tok');
    });

    it('fails closed on a stream cut off before its exit status, and on an error event', async () => {
        answers.push(() => new Response(sse(['output', { stream: 'stdout', chunk: 'partial' }])));
        await assert.rejects(exec(api, 'L1', ['spawn', 'x']), { message: 'simlock exec spawn x ended without an exit status (stream cut off)' });
        answers.push(() => new Response(sse(['error', { code: 'LEASE_EXPIRED', message: 'gone' }])));
        await assert.rejects(exec(api, 'L1', ['spawn', 'x']), { message: 'simlock exec spawn x failed: LEASE_EXPIRED gone' });
    });

    it('retries only a worker that dropped its uplink, and reports any other HTTP failure', async () => {
        answers.push(() => new Response('{"code":"WORKER_UNREACHABLE"}', { status: 503 }));
        answers.push(() => new Response(sse(['exit', { exitCode: 0 }])));
        assert.equal((await exec(api, 'L1', ['getenv'])).exitCode, 0);
        answers.push(() => new Response('nope', { status: 403 }));
        await assert.rejects(exec(api, 'L1', ['getenv']), { message: 'simlock POST /v1/leases/L1/exec answered 403: nope' });
    });

    it('mustExec fails on a non-zero exit with the command and its stderr', async () => {
        answers.push(() => new Response(sse(['output', { stream: 'stderr', chunk: ' no such app \n' }], ['exit', { exitCode: 2 }])));
        await assert.rejects(mustExec(api, 'L1', ['get_app_container', 'x', 'app', 'extra']), { message: 'simctl get_app_container x app exited 2: no such app' });
    });
});

type Reply = (request: IncomingMessage, response: ServerResponse) => void;

/** A stand-in gateway answering each request with the next reply (the last one repeats), and the requests it saw. */
async function gateway(replies: readonly Reply[]): Promise<{ url: string; requests: () => number; close: () => void }> {
    let seen = 0;
    const server = createServer((request, response) => {
        const reply = replies[Math.min(seen, replies.length - 1)]!;
        seen += 1;
        request.resume();
        request.on('end', () => reply(request, response));
    });
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
    return { url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, requests: () => seen, close: () => server.close() };
}

const reset: Reply = request => request.socket.destroy();
const cutMidStream: Reply = (_request, response) => {
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.write('event: output\n');
    setImmediate(() => response.socket?.destroy());
};
const exitZero: Reply = (_request, response) => {
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.end(sse(['output', { stream: 'stdout', chunk: 'ok' }], ['exit', { exitCode: 0 }]));
};
const forbidden: Reply = (_request, response) => {
    response.writeHead(403);
    response.end('{"error":"FORBIDDEN"}');
};

describe('exec over a tunnel that drops connections', () => {
    // The real transport: the stand-in gateway, not the fetch stub.
    beforeEach(() => {
        globalThis.fetch = realFetch;
    });

    it('asks again when the connection is reset before the answer', async () => {
        const farm = await gateway([reset, exitZero]);
        try {
            assert.deepEqual(await exec({ url: farm.url, token: 't' }, 'lease', ['spawn', 'true']), { exitCode: 0, stdout: 'ok', stderr: '' });
            assert.equal(farm.requests(), 2);
        } finally {
            farm.close();
        }
    });

    it('asks again when the answer is cut off mid-stream', async () => {
        const farm = await gateway([cutMidStream, exitZero]);
        try {
            assert.equal((await exec({ url: farm.url, token: 't' }, 'lease', ['spawn', 'true'])).exitCode, 0);
            assert.equal(farm.requests(), 2);
        } finally {
            farm.close();
        }
    });

    it('fails closed after exactly three attempts when the transport keeps failing', async () => {
        const farm = await gateway([reset]);
        try {
            await assert.rejects(exec({ url: farm.url, token: 't' }, 'lease', ['spawn', 'true']), /fetch failed/);
            assert.equal(farm.requests(), 3);
        } finally {
            farm.close();
        }
    });

    it('never asks again after an error the gateway answered', async () => {
        const farm = await gateway([forbidden, exitZero]);
        try {
            await assert.rejects(exec({ url: farm.url, token: 't' }, 'lease', ['spawn', 'true']), { message: 'simlock POST /v1/leases/lease/exec answered 403: {"error":"FORBIDDEN"}' });
            assert.equal(farm.requests(), 1);
        } finally {
            farm.close();
        }
    });
});

describe('drop', () => {
    beforeEach(() => {
        globalThis.fetch = realFetch;
    });

    /** Answers get_app_container with a path, every spawn with exit 0, and records each spawn's arrival time. */
    async function dropGateway() {
        const spawns: number[] = [];
        const server = createServer(async (request, response) => {
            const chunks: Buffer[] = [];
            for await (const chunk of request) chunks.push(chunk as Buffer);
            const args = (JSON.parse(Buffer.concat(chunks).toString('utf8')) as { args: string[] }).args;
            if (args[0] === 'spawn') spawns.push(Date.now());
            response.writeHead(200, { 'content-type': 'text/event-stream' });
            response.end(args[0] === 'get_app_container' ? sse(['output', { stream: 'stdout', chunk: '/drop' }], ['exit', { exitCode: 0 }]) : sse(['exit', { exitCode: 0 }]));
        });
        await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
        const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
        return { api: { url, token: 't' }, spawns, close: () => server.close() };
    }

    it("sends a large payload only in a free transfer slot, shared with the farm's app uploads", async () => {
        const farm = await dropGateway();
        try {
            configureTransfers(farm.api.url, 1);
            let release!: () => void;
            const holding = transfer(farm.api.url, () => new Promise<void>(resolve => (release = resolve)));
            await new Promise(resolve => setTimeout(resolve, 20));
            const big = drop(farm.api, 'lease-big', ['write', '/tmp/f'], randomBytes(1_200_000));
            await new Promise(resolve => setTimeout(resolve, 400));
            assert.equal(farm.spawns.length, 0, 'the large drop waits while the only slot is held');
            const released = Date.now();
            release();
            await holding;
            assert.equal((await big).exitCode, 0);
            assert.ok(farm.spawns[0]! >= released);
        } finally {
            farm.close();
        }
    });

    it('sends a small payload at once, without a slot', async () => {
        const farm = await dropGateway();
        try {
            configureTransfers(farm.api.url, 1);
            let release!: () => void;
            const holding = transfer(farm.api.url, () => new Promise<void>(resolve => (release = resolve)));
            assert.equal((await drop(farm.api, 'lease-small', ['write', '/tmp/f'], Buffer.from('small'))).exitCode, 0);
            release();
            await holding;
        } finally {
            farm.close();
        }
    });
});

describe('leaseIdForUdid', () => {
    it('finds the lease holding the device, and fails closed when none does', async () => {
        answers.push(() => new Response(JSON.stringify({ leases: [{ id: 'L1' }, { id: 'L2', deviceKey: 'android:mobile:emulator-5588' }] })));
        answers.push(() => new Response('{"id":"L1","deviceKey":"android:mobile:emulator-5586"}'));
        assert.equal(await leaseIdForUdid(api, 'emulator-5588'), 'L2');
        answers.push(() => new Response(JSON.stringify({ leases: [] })));
        await assert.rejects(leaseIdForUdid(api, 'U-1'), { message: 'no simlock lease of this token holds U-1 (0 leases)' });
    });
});

describe('E2E_DROP_APP', () => {
    it("names the package's prebuilt simulator helper", () => {
        assert.ok(existsSync(fileURLToPath(new URL('Info.plist', `file://${E2E_DROP_APP}/`))));
    });
});
