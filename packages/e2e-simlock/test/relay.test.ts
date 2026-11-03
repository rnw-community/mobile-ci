import assert from 'node:assert/strict';
import { createServer, request, type Server } from 'node:http';
import { after, before, describe, it } from 'node:test';

import { localReply, startBootRelay, upstreamPath, type BootRelay } from '../src/relay.ts';

import type { AddressInfo } from 'node:net';

describe('upstreamPath', () => {
    it('maps an origin-form target under the gateway base path', () => {
        assert.equal(upstreamPath('/v1/agent-device/', '/rpc'), '/v1/agent-device/rpc');
        assert.equal(upstreamPath('/v1/agent-device', '/upload?x=1&y=%20'), '/v1/agent-device/upload?x=1&y=%20');
    });

    it('refuses any target that could leave the gateway', () => {
        for (const target of ['http://evil.test/', '//evil.test/x', '/a/../b', '/..', '/./x', '/x/.', '/%2e%2e/x', '/a%2Fb', '/a%5cb', '/a b', '/a\\b', 'rpc', '']) {
            assert.equal(upstreamPath('/v1/agent-device', target), undefined, target);
        }
    });
});

const parse = (reply: Buffer | undefined) => (reply === undefined ? undefined : JSON.parse(reply.toString('utf8')));

describe('localReply', () => {
    it('answers boot for a simulator UDID and for an emulator serial, already booted', () => {
        assert.deepEqual(parse(localReply({ id: 1, params: { command: 'boot', flags: { udid: 'U-1' } } })), {
            jsonrpc: '2.0',
            id: 1,
            result: { ok: true, data: { platform: 'ios', target: 'mobile', device: 'U-1', id: 'U-1', kind: 'simulator', booted: true } }
        });
        assert.deepEqual(parse(localReply({ id: 2, params: { command: 'boot', flags: { serial: 'emulator-5586' } } }))?.result.data, {
            platform: 'android',
            target: 'mobile',
            device: 'emulator-5586',
            id: 'emulator-5586',
            kind: 'emulator',
            booted: true
        });
    });

    it('refuses a boot that names no device', () => {
        assert.deepEqual(parse(localReply({ id: 3, params: { command: 'boot', flags: {} } }))?.error, {
            code: -32000,
            message: 'simlock relay: boot names no udid or serial',
            data: { code: 'INVALID_ARGS', message: 'simlock relay: boot names no udid or serial' }
        });
    });

    it('answers a bare session close, which would end the lease, and forwards a close of an app', () => {
        assert.deepEqual(parse(localReply({ id: 4, params: { command: 'close', session: 's-1' } }))?.result, {
            ok: true,
            data: { session: 's-1', identifiers: { session: 's-1' } }
        });
        assert.equal(localReply({ id: 5, params: { command: 'close', positionals: ['com.example'] } }), undefined);
        assert.equal(localReply({ id: 6, params: { command: 'snapshot' } }), undefined);
    });
});

describe('startBootRelay', () => {
    let upstream: Server;
    let relay: BootRelay;
    let gatewayHost = '';
    const seen: { method: string; url: string; body: string; host: string }[] = [];

    before(async () => {
        upstream = createServer(async (req, res) => {
            const chunks: Buffer[] = [];
            for await (const chunk of req) {
                chunks.push(chunk as Buffer);
            }
            seen.push({ method: req.method!, url: req.url!, body: Buffer.concat(chunks).toString('utf8'), host: req.headers.host! });
            res.writeHead(200, { 'content-type': 'text/plain', connection: 'close' });
            res.end(`upstream ${req.url}`);
        });
        await new Promise<void>(resolve => upstream.listen(0, '127.0.0.1', resolve));
        gatewayHost = `127.0.0.1:${(upstream.address() as AddressInfo).port}`;
        relay = await startBootRelay(`http://${gatewayHost}/v1/agent-device`);
    });

    after(async () => {
        await relay.close();
        await new Promise(resolve => upstream.close(resolve));
    });

    const send = (method: string, path: string, body?: string) =>
        new Promise<{ status: number; body: string }>((resolve, reject) => {
            const out = request(`${relay.baseUrl}${path.startsWith('/') ? '' : '/'}`, { method, path }, res => {
                const chunks: Buffer[] = [];
                res.on('data', (chunk: Buffer) => chunks.push(chunk));
                res.on('end', () => resolve({ status: res.statusCode!, body: Buffer.concat(chunks).toString('utf8') }));
            });
            out.on('error', reject);
            out.end(body);
        });

    it('forwards other requests to the gateway base path, with the gateway as host', async () => {
        seen.length = 0;
        const reply = await send('GET', '/upload?id=1');
        assert.deepEqual(reply, { status: 200, body: 'upstream /v1/agent-device/upload?id=1' });
        assert.equal(seen[0]!.host, gatewayHost);
        const rpc = JSON.stringify({ jsonrpc: '2.0', id: 9, params: { command: 'snapshot' } });
        assert.equal((await send('POST', '/rpc', rpc)).body, 'upstream /v1/agent-device/rpc');
        assert.equal(seen[1]!.body, rpc);
    });

    it('answers boot without reaching the gateway', async () => {
        seen.length = 0;
        const reply = await send('POST', '/rpc', JSON.stringify({ id: 1, params: { command: 'boot', flags: { serial: 'emulator-5554' } } }));
        assert.equal(reply.status, 200);
        assert.equal(JSON.parse(reply.body).result.data.kind, 'emulator');
        assert.equal(seen.length, 0);
    });

    it('refuses a target that could leave the gateway, before any request goes out', async () => {
        seen.length = 0;
        const reply = await send('GET', '//evil.test/x');
        assert.deepEqual(reply, { status: 400, body: 'simlock relay: refused request target //evil.test/x' });
        assert.equal(seen.length, 0);
    });

    it('answers 502 when the gateway is unreachable', async () => {
        const dead = await startBootRelay('http://127.0.0.1:1/v1/agent-device');
        try {
            const reply = await new Promise<{ status: number; body: string }>((resolve, reject) => {
                const out = request(`${dead.baseUrl}/rpc`, { method: 'POST' }, res => {
                    const chunks: Buffer[] = [];
                    res.on('data', (chunk: Buffer) => chunks.push(chunk));
                    res.on('end', () => resolve({ status: res.statusCode!, body: Buffer.concat(chunks).toString('utf8') }));
                });
                out.on('error', reject);
                out.end(JSON.stringify({ id: 1, params: { command: 'snapshot' } }));
            });
            assert.equal(reply.status, 502);
            assert.match(reply.body, /^simlock relay: Error: connect ECONNREFUSED/);
        } finally {
            await dead.close();
        }
    });
});
