import { createServer, request as httpRequest, type IncomingMessage, type Server } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { pipeline } from 'node:stream/promises';

import type { AddressInfo } from 'node:net';

/**
 * A loopback relay in front of simlock's agent-device proxy. simlock grants devices already
 * booted and denies `boot`, while the mobile engine boots its device in `prepare`: the relay
 * answers `boot` for the simulator UDID or emulator serial the engine names. A bare session
 * `close` would end the simlock lease and wipe the device mid-run (the engine closes a slot's
 * session on a worker respawn), so the relay answers that too; the provider releases the lease
 * at the end of the run. Every other request, uploads included, passes through untouched.
 */
export interface BootRelay {
    readonly baseUrl: string;
    close(): Promise<void>;
}

const DEBUG = process.env.SIMLOCK_RELAY_DEBUG === '1';

type Headers = Record<string, string | string[] | undefined>;

/** Headers that apply to one hop only (RFC 9110 §7.6.1), plus any the Connection header names. */
const HOP_BY_HOP = ['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization', 'proxy-connection', 'te', 'trailer', 'transfer-encoding', 'upgrade'];

function endToEnd(headers: Headers): Headers {
    const named = String(headers.connection ?? '')
        .split(',')
        .map(name => name.trim().toLowerCase())
        .filter(Boolean);
    const result: Headers = { ...headers };
    for (const name of [...HOP_BY_HOP, ...named]) {
        delete result[name];
    }
    return result;
}

/**
 * The upstream path for a request target: its path and query under the gateway's base path.
 * Anything but an origin-form target of plain path characters (an absolute-form
 * `http://elsewhere/`, `//host`, a `.` or `..` segment, an encoded `.`, `/` or `\`) is refused,
 * so the relay can only ever reach the configured gateway. Returns undefined for a refused target.
 */
export function upstreamPath(basePath: string, requestTarget: string): string | undefined {
    if (
        !/^\/(?!\/)[A-Za-z0-9._~!$&'()*+,;=:@%/?-]*$/.test(requestTarget) ||
        /(^|\/)\.\.?(\/|\?|$)/.test(requestTarget) ||
        /%(2e|2f|5c)/i.test(requestTarget)
    ) {
        return undefined;
    }
    return `${basePath.replace(/\/+$/, '')}${requestTarget}`;
}

const rpcReply = (id: unknown, result: unknown): Buffer => Buffer.from(JSON.stringify({ jsonrpc: '2.0', id, result }));

const rpcError = (id: unknown, message: string): Buffer =>
    Buffer.from(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32000, message, data: { code: 'INVALID_ARGS', message } } }));

/** The answer for an RPC the relay handles itself, or undefined to forward it. */
export function localReply(rpc: { id?: unknown; params?: Record<string, unknown> }): Buffer | undefined {
    const params = rpc.params ?? {};
    const positionals = Array.isArray(params.positionals) ? params.positionals : [];
    if (params.command === 'close' && positionals.length === 0) {
        const session = typeof params.session === 'string' ? params.session : '';
        return rpcReply(rpc.id, { ok: true, data: { session, identifiers: { session: params.session } } });
    }
    if (params.command !== 'boot') {
        return undefined;
    }
    const flags = (params.flags ?? {}) as Record<string, unknown>;
    if (typeof flags.udid === 'string') {
        return rpcReply(rpc.id, { ok: true, data: { platform: 'ios', target: 'mobile', device: flags.udid, id: flags.udid, kind: 'simulator', booted: true } });
    }
    if (typeof flags.serial === 'string') {
        return rpcReply(rpc.id, { ok: true, data: { platform: 'android', target: 'mobile', device: flags.serial, id: flags.serial, kind: 'emulator', booted: true } });
    }
    return rpcError(rpc.id, 'simlock relay: boot names no udid or serial');
}

export async function startBootRelay(upstreamBaseUrl: string): Promise<BootRelay> {
    const upstream = new URL(upstreamBaseUrl.endsWith('/') ? upstreamBaseUrl : `${upstreamBaseUrl}/`);
    const send = upstream.protocol === 'https:' ? httpsRequest : httpRequest;

    const forward = (incoming: IncomingMessage, path: string, body?: Buffer) =>
        new Promise<{ status: number; headers: Headers; body?: Buffer; stream?: IncomingMessage }>((resolve, reject) => {
            const headers: Headers = { ...endToEnd(incoming.headers), host: upstream.host };
            if (body !== undefined) {
                headers['content-length'] = String(body.length);
            }
            const out = send(
                {
                    protocol: upstream.protocol,
                    hostname: upstream.hostname,
                    port: upstream.port === '' ? undefined : Number(upstream.port),
                    path,
                    method: incoming.method,
                    headers
                },
                response => {
                    if (body === undefined) {
                        resolve({ status: response.statusCode ?? 502, headers: response.headers, stream: response });
                        return;
                    }
                    const chunks: Buffer[] = [];
                    response.on('data', (chunk: Buffer) => chunks.push(chunk));
                    response.on('end', () => resolve({ status: response.statusCode ?? 502, headers: response.headers, body: Buffer.concat(chunks) }));
                    response.on('error', reject);
                }
            );
            out.on('error', reject);
            if (body === undefined) {
                incoming.pipe(out);
            } else {
                out.end(body);
            }
        });

    const server: Server = createServer(async (incoming, outgoing) => {
        const target = incoming.url ?? '/';
        const path = upstreamPath(upstream.pathname, target);
        if (path === undefined) {
            outgoing.writeHead(400, { 'content-type': 'text/plain' });
            outgoing.end(`simlock relay: refused request target ${target}`);
            return;
        }
        try {
            if (incoming.method !== 'POST' || !(target === '/rpc' || target.startsWith('/rpc?'))) {
                const reply = await forward(incoming, path);
                outgoing.writeHead(reply.status, endToEnd(reply.headers));
                // A client that goes away stops the upstream transfer, and a broken upstream ends the reply.
                pipeline(reply.stream!, outgoing).catch(() => reply.stream!.destroy());
                return;
            }
            const chunks: Buffer[] = [];
            for await (const chunk of incoming) {
                chunks.push(chunk as Buffer);
            }
            const raw = Buffer.concat(chunks);
            const rpc = JSON.parse(raw.toString('utf8')) as { id?: unknown; params?: Record<string, unknown> };
            const local = localReply(rpc);
            if (DEBUG) {
                console.error(`[relay] ${String(rpc.params?.command)} ${local === undefined ? 'forwarded' : 'answered locally'}`);
            }
            if (local !== undefined) {
                outgoing.writeHead(200, { 'content-type': 'application/json', 'content-length': String(local.length) });
                outgoing.end(local);
                return;
            }
            const reply = await forward(incoming, path, raw);
            outgoing.writeHead(reply.status, endToEnd(reply.headers));
            outgoing.end(reply.body);
        } catch (cause) {
            outgoing.writeHead(502, { 'content-type': 'text/plain' });
            outgoing.end(`simlock relay: ${String(cause)}`);
        }
    });
    await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
    const { port } = server.address() as AddressInfo;
    return {
        baseUrl: `http://127.0.0.1:${port}`,
        close: () => new Promise(resolve => server.close(() => resolve()))
    };
}
