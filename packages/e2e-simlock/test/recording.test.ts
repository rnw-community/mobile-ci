import assert from 'node:assert/strict';
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, it } from 'node:test';

import { measureRecording, repeatStats } from '../src/recording.ts';

const FRAME_BYTES = 128 * 256;

describe('repeatStats', () => {
    const flags = (text: string) => [...text].map(mark => mark === '.');

    it('counts the frames that repeat the one before', () => {
        assert.deepEqual(repeatStats(flags('xx.xx.x')), { repeatedFrames: 2, longestStallFrames: 1 });
        assert.deepEqual(repeatStats([]), { repeatedFrames: 0, longestStallFrames: 0 });
    });

    it('takes the longest run', () => {
        assert.deepEqual(repeatStats(flags('x..xx.....xx...')), { repeatedFrames: 10, longestStallFrames: 5 });
    });

    it("bridges one changed frame between repeats: hevc refreshes a stale image about every tenth frame", () => {
        assert.deepEqual(repeatStats(flags('xx.....x.....x.....xx')), { repeatedFrames: 15, longestStallFrames: 17 });
    });

    it('does not bridge two changed frames, or a changed frame after a single repeat at the end', () => {
        assert.deepEqual(repeatStats(flags('..xx..')), { repeatedFrames: 4, longestStallFrames: 2 });
        assert.deepEqual(repeatStats(flags('x.x')), { repeatedFrames: 1, longestStallFrames: 1 });
    });
});

describe('measureRecording', () => {
    const realPath = process.env.PATH;
    const dirs: string[] = [];
    afterEach(() => {
        process.env.PATH = realPath;
        dirs.splice(0).forEach(dir => rmSync(dir, { recursive: true, force: true }));
    });

    /** Stand-in ffmpeg and ffprobe: `frames` are the bytes ffmpeg writes to stdout. */
    function stubs(frames: Buffer, { ffmpegExit = 0, duration = '2.000000' } = {}): string {
        const dir = mkdtempSync(join(tmpdir(), 'measure-recording-'));
        dirs.push(dir);
        writeFileSync(join(dir, 'frames'), frames);
        writeFileSync(join(dir, 'ffmpeg'), `#!/bin/sh\necho "$@" > "${dir}/ffmpeg.args"\ncat "${dir}/frames"\n[ ${ffmpegExit} -eq 0 ] || echo 'corrupt input' >&2\nexit ${ffmpegExit}\n`);
        writeFileSync(join(dir, 'ffprobe'), `#!/bin/sh\necho ${duration}\n`);
        chmodSync(join(dir, 'ffmpeg'), 0o755);
        chmodSync(join(dir, 'ffprobe'), 0o755);
        process.env.PATH = `${dir}:${realPath}`;
        return dir;
    }
    const frame = (value: number, changed = 0): Buffer => {
        const bytes = Buffer.alloc(FRAME_BYTES, value);
        bytes.fill(value + 50, 0, changed);
        return bytes;
    };

    it('reports the frame count against the duration, the repeats, and the longest stall', async () => {
        stubs(Buffer.concat([frame(10), frame(60), frame(61), frame(62), frame(62), frame(100)]));
        assert.deepEqual(await measureRecording('clip.mp4'), { frames: 6, durationMs: 2000, repeatedFrames: 3, longestStallFrames: 3, longestStallMs: 1000 });
    });

    it('reads frames across the chunks a pipe splits them into', async () => {
        stubs(Buffer.concat(Array.from({ length: 40 }, (_, index) => frame(index * 5))));
        const stats = await measureRecording('clip.mp4');
        assert.deepEqual([stats.frames, stats.repeatedFrames], [40, 0]);
    });

    it('counts a frame as changed on any one pixel, so a small moving witness is no repeat', async () => {
        stubs(Buffer.concat([frame(10), frame(10, 1), frame(10)]));
        assert.equal((await measureRecording('clip.mp4')).repeatedFrames, 0);
    });

    it('passes every frame through as decoded, without duplicating or dropping any', async () => {
        const dir = stubs(frame(10));
        await measureRecording('clip.mp4');
        assert.match(readFileSync(join(dir, 'ffmpeg.args'), 'utf8'), /-i clip\.mp4 .*-fps_mode passthrough .*scale=128:256,format=gray -f rawvideo -/);
    });

    it('fails closed on a tool that fails, a truncated frame, an empty clip or an unreadable duration', async () => {
        stubs(frame(10), { ffmpegExit: 1 });
        await assert.rejects(measureRecording('clip.mp4'), /^Error: measureRecording: ffmpeg on clip\.mp4 exited 1: corrupt input/);
        stubs(Buffer.alloc(FRAME_BYTES + 1));
        await assert.rejects(measureRecording('clip.mp4'), { message: `measureRecording: ffmpeg on clip.mp4 wrote a partial frame (${FRAME_BYTES + 1} bytes)` });
        stubs(Buffer.alloc(0));
        await assert.rejects(measureRecording('clip.mp4'), { message: 'measureRecording: clip.mp4 has no video frames' });
        stubs(frame(10), { duration: 'N/A' });
        await assert.rejects(measureRecording('clip.mp4'), { message: "measureRecording: ffprobe on clip.mp4 gave no duration ('N/A')" });
    });

    it('names the tool it needs when ffmpeg is missing', async () => {
        process.env.PATH = '/nonexistent';
        await assert.rejects(measureRecording('clip.mp4'), /^Error: measureRecording needs ffmpeg and ffprobe on PATH/);
    });
});
