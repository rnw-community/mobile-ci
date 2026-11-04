import { spawn } from 'node:child_process';

/** Frames are compared as small grey thumbnails: enough to see a scroll, and they cost little to decode. */
const WIDTH = 128;
const HEIGHT = 256;
const FRAME_BYTES = WIDTH * HEIGHT;
/** Lossy encoding leaves a repeated image a level or two off the one before; a real change moves a pixel further. */
const SAME_LEVELS = 2;

export interface RecordingStats {
    readonly frames: number;
    readonly durationMs: number;
    /** Frames whose picture repeats the frame before. */
    readonly repeatedFrames: number;
    /** The longest run of them. One changed frame between repeats does not end it: the encoder refreshes a stale image about every tenth frame. */
    readonly longestStallFrames: number;
    /** That run at the clip's average frame rate. */
    readonly longestStallMs: number;
}

/** The repeat counts for each frame after the first: `repeated[i]` says that frame repeats the one before it. */
export function repeatStats(repeated: readonly boolean[]): Pick<RecordingStats, 'repeatedFrames' | 'longestStallFrames'> {
    let longestStallFrames = 0;
    let run = 0;
    repeated.forEach((same, index) => {
        run = same || (run > 0 && repeated[index + 1] === true && repeated[index - 1] === true) ? run + 1 : 0;
        longestStallFrames = Math.max(longestStallFrames, run);
    });
    return { repeatedFrames: repeated.filter(Boolean).length, longestStallFrames };
}

/** Runs a tool, feeding its stdout to `onData`; fails closed on a missing tool or a non-zero exit. */
function run(tool: string, file: string, args: readonly string[], onData: (chunk: Buffer) => void): Promise<void> {
    return new Promise((resolve, reject) => {
        const child = spawn(tool, args, { stdio: ['ignore', 'pipe', 'pipe'] });
        let stderr = '';
        child.stdout.on('data', onData);
        child.stderr.on('data', (chunk: Buffer) => (stderr += chunk.toString()));
        child.on('error', cause => reject(new Error(`measureRecording needs ffmpeg and ffprobe on PATH: ${String(cause)}`)));
        child.on('close', code => (code === 0 ? resolve() : reject(new Error(`measureRecording: ${tool} on ${file} exited ${code}: ${stderr.trim()}`))));
    });
}

/**
 * How much of a recording repeats itself. A capture that stalls mid-clip decodes cleanly with monotonic timestamps, so
 * nothing else flags it. A still screen repeats frames too, so the caller, who knows the clip should move, decides:
 * fail or capture again when `longestStallMs` is too long. Needs `ffmpeg` and `ffprobe` on PATH.
 */
export async function measureRecording(file: string): Promise<RecordingStats> {
    const repeated: boolean[] = [];
    let previous: Buffer | undefined;
    let pending = Buffer.alloc(0);
    await run('ffmpeg', file, ['-v', 'error', '-i', file, '-map', '0:v:0', '-fps_mode', 'passthrough', '-vf', `scale=${WIDTH}:${HEIGHT},format=gray`, '-f', 'rawvideo', '-'], chunk => {
        pending = Buffer.concat([pending, chunk]);
        for (; pending.length >= FRAME_BYTES; pending = pending.subarray(FRAME_BYTES)) {
            const frame = pending.subarray(0, FRAME_BYTES);
            if (previous !== undefined) {
                const before = previous;
                repeated.push(frame.every((level, pixel) => Math.abs(level - before[pixel]!) <= SAME_LEVELS));
            }
            previous = frame;
        }
    });
    if (pending.length > 0) {
        throw new Error(`measureRecording: ffmpeg on ${file} wrote a partial frame (${(repeated.length + 1) * FRAME_BYTES + pending.length} bytes)`);
    }
    if (previous === undefined) {
        throw new Error(`measureRecording: ${file} has no video frames`);
    }
    let probed = '';
    await run('ffprobe', file, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file], chunk => (probed += chunk.toString()));
    const durationMs = Math.round(Number(probed.trim()) * 1000);
    if (!(durationMs > 0)) {
        throw new Error(`measureRecording: ffprobe on ${file} gave no duration ('${probed.trim()}')`);
    }
    const frames = repeated.length + 1;
    const stats = repeatStats(repeated);
    return { frames, durationMs, ...stats, longestStallMs: Math.round((stats.longestStallFrames * durationMs) / frames) };
}
