import { fileURLToPath } from 'node:url';
import { deflateRawSync } from 'node:zlib';

import { LARGE_PAYLOAD_BYTES, transfer } from './transfers.ts';
import { acrossTunnel } from './tunnel.ts';

/**
 * Host-side device work over simlock's HTTP API, for test fixtures. `POST /v1/leases/<id>/exec` runs one
 * `simctl` or `adb` command on the worker for the leased device only (simlock inserts the UDID or serial).
 * The file helpers are iOS only: `simctl spawn … /bin/sh -c` runs the simulator
 * runtime's shell, which reaches the Mac's own `/bin` and `/usr/bin` by
 * absolute path, so files travel as base64 on stdin and are unpacked by the
 * worker's own tools: the runner needs no SSH key and no shared disk.
 */
export interface SimlockApi {
    readonly url: string;
    readonly token: string;
}

export interface ExecResult {
    readonly exitCode: number;
    readonly stdout: string;
    readonly stderr: string;
}

export function simlockApiFromEnv(env: NodeJS.ProcessEnv = process.env): SimlockApi {
    const url = env.SIMLOCK_URL;
    const token = env.SIMLOCK_TOKEN;
    if (!url || !token) {
        throw new Error('SIMLOCK_URL and SIMLOCK_TOKEN are required');
    }
    return { url, token };
}

/** No request to the farm may hang a test: a simctl exec (an untar included) gets its 10 minute cap. */
const REQUEST_TIMEOUT_MS = 11 * 60_000;

async function call(api: SimlockApi, path: string, init: RequestInit = {}): Promise<Response> {
    const response = await fetch(`${api.url.replace(/\/$/, '')}${path}`, {
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
        ...init,
        headers: { authorization: `Bearer ${api.token}`, 'content-type': 'application/json', ...init.headers }
    });
    if (!response.ok) {
        throw new Error(`simlock ${init.method ?? 'GET'} ${path} answered ${response.status}: ${await response.text()}`);
    }
    return response;
}

/** The simlock lease of this token that holds the device with this id (a simulator UDID or an emulator serial). */
export async function leaseIdForUdid(api: SimlockApi, udid: string): Promise<string> {
    const body = (await (await call(api, '/v1/leases')).json()) as { leases: Record<string, unknown>[] };
    for (const lease of body.leases) {
        if (JSON.stringify(lease).includes(udid)) {
            return String(lease.id);
        }
        const detail = await (await call(api, `/v1/leases/${String(lease.id)}`)).text();
        if (detail.includes(udid)) {
            return String(lease.id);
        }
    }
    throw new Error(`no simlock lease of this token holds ${udid} (${body.leases.length} leases)`);
}

/** undici's wording for a connection lost before (`fetch failed`) or during (`terminated`) the answer, and simlock's for a lost worker. */
const TRANSIENT = /WORKER_UNREACHABLE|fetch failed|terminated/;

export type ExecTool = 'simctl' | 'adb';

const PLATFORM_TOOLS: Record<string, ExecTool> = { ios: 'simctl', android: 'adb' };

const leaseTools = new Map<string, Promise<ExecTool>>();

/** The tool that serves this lease's platform, asked of the farm once per lease. */
function leaseTool(api: SimlockApi, leaseId: string): Promise<ExecTool> {
    return remembered(leaseTools, leaseId, async () => {
        const { lease } = (await (await call(api, `/v1/leases/${leaseId}`)).json()) as { lease?: { platform?: string } };
        const platform = lease?.platform;
        const tool = PLATFORM_TOOLS[platform ?? ''];
        if (tool === undefined) {
            throw new Error(`simlock lease ${leaseId} is on platform '${platform}': exec needs a tool, 'simctl' or 'adb'`);
        }
        return tool;
    });
}

/** Runs `work` once per key; a failure is forgotten, so the next caller asks again. */
function remembered<T>(known: Map<string, Promise<T>>, key: string, work: () => Promise<T>): Promise<T> {
    let result = known.get(key);
    if (result === undefined) {
        result = work();
        known.set(key, result);
        result.catch(() => known.delete(key));
    }
    return result;
}

/**
 * Runs one command on the leased device: `tool` defaults to the one its platform has (`simctl` on iOS, `adb` on
 * Android). A payload over 1 MiB takes one of the machine-wide transfer slots app uploads use (`installConcurrency`).
 */
export async function exec(api: SimlockApi, leaseId: string, args: readonly string[], stdin?: string, tool?: ExecTool): Promise<ExecResult> {
    if (tool !== undefined && !Object.values(PLATFORM_TOOLS).includes(tool)) {
        throw new Error(`exec: tool must be 'simctl' or 'adb'; got '${String(tool)}'`);
    }
    const resolved = tool ?? (await leaseTool(api, leaseId));
    const body = JSON.stringify({ tool: resolved, args, ...(stdin === undefined ? {} : { stdin }) });
    // One attempt is the request and its whole answer: the tunnel can drop either. A gateway's worker uplink can
    // drop and reconnect within a second too; every command the suite sends is idempotent. An error the gateway
    // answered, or the request timeout, is not transient.
    const send = () =>
        acrossTunnel(
            async () => (await call(api, `/v1/leases/${leaseId}/exec`, { method: 'POST', body })).text(),
            cause => TRANSIENT.test(String(cause))
        );
    const text = await (stdin !== undefined && stdin.length > LARGE_PAYLOAD_BYTES ? transfer(api.url, send) : send());
    let stdout = '';
    let stderr = '';
    let exitCode = -1;
    let sawExit = false;
    let event = '';
    for (const line of text.split('\n')) {
        if (line.startsWith('event: ')) {
            event = line.slice(7).trim();
        } else if (line.startsWith('data: ')) {
            const data = JSON.parse(line.slice(6)) as {
                stream?: string;
                chunk?: string;
                exitCode?: number;
                code?: string;
                message?: string;
            };
            if (event === 'output') {
                if (data.stream === 'stderr') {
                    stderr += data.chunk ?? '';
                } else {
                    stdout += data.chunk ?? '';
                }
            } else if (event === 'exit') {
                exitCode = data.exitCode ?? -1;
                sawExit = true;
            } else if (event === 'error') {
                throw new Error(`simlock exec ${args.slice(0, 2).join(' ')} failed: ${data.code} ${data.message}`);
            }
        }
    }
    // A stream cut off before its exit event says nothing about the command: never a result.
    if (!sawExit) {
        throw new Error(`simlock exec ${args.slice(0, 2).join(' ')} ended without an exit status (stream cut off)`);
    }
    return { exitCode, stdout, stderr };
}

export async function mustExec(api: SimlockApi, leaseId: string, args: readonly string[], stdin?: string, tool?: ExecTool): Promise<string> {
    const resolved = tool ?? (await leaseTool(api, leaseId));
    const result = await exec(api, leaseId, args, stdin, resolved);
    if (result.exitCode !== 0) {
        throw new Error(`${resolved} ${args.slice(0, 3).join(' ')} exited ${result.exitCode}: ${result.stderr.trim()}`);
    }
    return result.stdout;
}

/**
 * E2EDrop, a helper app built for the simulator (this package's `e2e-drop/`),
 * which the provider installs beside the app under test. CoreSimulator on
 * macOS 26 refuses to spawn the Mac's own tools and the simulator runtime has
 * no shell, cp or tar, so every file the suite puts on the device goes
 * through it.
 */
export const E2E_DROP_APP = fileURLToPath(new URL('../e2e-drop/E2EDrop.app', import.meta.url));
const E2E_DROP_BUNDLE_ID = 'dev.e2e.simlock.drop';

const dropPaths = new Map<string, Promise<string>>();

function dropExecutable(api: SimlockApi, leaseId: string): Promise<string> {
    return remembered(dropPaths, leaseId, async () => `${(await mustExec(api, leaseId, ['get_app_container', E2E_DROP_BUNDLE_ID, 'app'], undefined, 'simctl')).trim()}/E2EDrop`);
}

/** Runs one E2EDrop command on the leased simulator; `payload` travels on stdin. */
export async function drop(api: SimlockApi, leaseId: string, args: readonly string[], payload?: Buffer): Promise<ExecResult> {
    const executable = await dropExecutable(api, leaseId);
    const stdin = payload === undefined ? undefined : deflateRawSync(payload).toString('base64');
    return exec(api, leaseId, ['spawn', executable, ...args], stdin, 'simctl');
}

export async function mustDrop(api: SimlockApi, leaseId: string, args: readonly string[], payload?: Buffer): Promise<string> {
    const result = await drop(api, leaseId, args, payload);
    if (result.exitCode !== 0) {
        throw new Error(`e2e-drop ${args[0]} exited ${result.exitCode}: ${result.stderr.trim()}`);
    }
    return result.stdout;
}

/** Writes `bytes` to `path` on the device's filesystem. */
export async function writeFile(api: SimlockApi, leaseId: string, path: string, bytes: Buffer): Promise<void> {
    await mustDrop(api, leaseId, ['write', path], bytes);
}

/** Unpacks a ustar archive (`tar --format=ustar`) into `dir`. */
export async function untar(api: SimlockApi, leaseId: string, dir: string, tar: Buffer): Promise<void> {
    await mustDrop(api, leaseId, ['untar', dir], tar);
}
