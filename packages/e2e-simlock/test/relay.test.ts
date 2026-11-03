import assert from 'node:assert/strict';
import { createServer, request, type Server } from 'node:http';
import { after, before, describe, it } from 'node:test';

import { localReply, rewritten, startBootRelay, upstreamPath, type BootRelay } from '../src/relay.ts';

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

describe('rewritten', () => {
    const allocate = { jsonrpc: '2.0', id: 7, method: 'agent_device.lease.allocate', params: { platform: 'ios', device: 'iPhone 17 Pro' } };
    const screenshot = { jsonrpc: '2.0', id: 8, method: 'agent_device.command', params: { command: 'screenshot', positionals: ['/tmp/a.png'], flags: { udid: 'U', screenshotPixelDensity: 3 } } };

    it("puts the target's deviceMode on a lease allocate, either method spelling", () => {
        assert.deepEqual(rewritten(allocate, { deviceMode: 'full' }), { ...allocate, params: { platform: 'ios', device: 'iPhone 17 Pro', deviceMode: 'full' } });
        assert.equal(rewritten({ ...allocate, method: 'agent-device.lease.allocate' }, { deviceMode: 'slim' })?.params?.deviceMode, 'slim');
        assert.deepEqual(rewritten({ id: 1, method: 'agent_device.lease.allocate' }, { deviceMode: 'full' })?.params, { deviceMode: 'full' });
    });

    it('takes an iOS screenshot from the runner, without the pixel density the daemon refuses beside it', () => {
        assert.deepEqual(rewritten(screenshot, { runnerScreenshots: true }), {
            ...screenshot,
            params: { command: 'screenshot', positionals: ['/tmp/a.png'], flags: { udid: 'U', screenshotCaptureBackend: 'runner' } }
        });
        assert.deepEqual(rewritten({ ...screenshot, params: { command: 'screenshot' } }, { runnerScreenshots: true })?.params, {
            command: 'screenshot',
            flags: { screenshotCaptureBackend: 'runner' }
        });
        assert.equal(screenshot.params.flags.screenshotPixelDensity, 3, 'the original request is not mutated');
    });

    it('leaves everything else as sent: other commands, lease calls, and a target that asked for neither', () => {
        const all = { deviceMode: 'full' as const, runnerScreenshots: true };
        for (const command of ['click', 'snapshot', 'record']) {
            assert.equal(rewritten({ ...screenshot, params: { ...screenshot.params, command } }, all), undefined, command);
        }
        for (const method of ['agent_device.lease.heartbeat', 'agent_device.lease.release', 'agent_device.lease.allocated', undefined]) {
            assert.equal(rewritten({ ...allocate, method }, all), undefined, String(method));
        }
        assert.equal(rewritten({ ...screenshot, method: 'agent_device.lease.allocate' }, { runnerScreenshots: true }), undefined);
        assert.equal(rewritten(allocate, {}), undefined);
        assert.equal(rewritten(screenshot, { deviceMode: 'full' }), undefined, 'a target without the runner option keeps the default capture (Android)');
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

    it("rewrites what the target asked for on the wire, and forwards any other body byte for byte", async () => {
        const full = await startBootRelay(`http://${gatewayHost}/v1/agent-device`, { deviceMode: 'full', runnerScreenshots: true });
        try {
            seen.length = 0;
            const post = (body: string) =>
                new Promise<number>((resolve, reject) => {
                    const out = request(`${full.baseUrl}/rpc`, { method: 'POST' }, res => {
                        res.resume();
                        res.on('end', () => resolve(res.statusCode!));
                    });
                    out.on('error', reject);
                    out.end(body);
                });
            await post(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'agent_device.lease.allocate', params: { platform: 'ios' } }));
            const command = '{"jsonrpc":"2.0","id":2,"method":"agent_device.command","params":{"command":"snapshot"}}';
            await post(command);
            await post(JSON.stringify({ jsonrpc: '2.0', id: 3, method: 'agent_device.command', params: { command: 'screenshot', flags: { screenshotPixelDensity: 3 } } }));
            assert.deepEqual(JSON.parse(seen[0]!.body), { jsonrpc: '2.0', id: 1, method: 'agent_device.lease.allocate', params: { platform: 'ios', deviceMode: 'full' } });
            assert.equal(seen[1]!.body, command);
            assert.deepEqual(JSON.parse(seen[2]!.body).params.flags, { screenshotCaptureBackend: 'runner' });
        } finally {
            await full.close();
        }
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
