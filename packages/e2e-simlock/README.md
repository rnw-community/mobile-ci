# @mobile-ci/e2e-simlock

A [tester-army e2e](https://github.com/tester-army/e2e) `DeviceProvider` that
leases iOS simulators and Android emulators from a
[simlock](https://github.com/callstackincubator/simlock) farm, so an e2e suite
runs from any Linux or macOS machine against devices the farm owns.

It ships inside `rnw-community/mobile-ci`, not on npm, and is versioned with
mobile-ci's release tags.

## Install

- **In CI** nothing to do: `ios-maestro.yml` and `android-maestro.yml`
  (`test-framework: e2e|both`) and `store-screenshots.yml`'s e2e driver install it
  into `e2e-dir` after the project's own install, from the same tag as the
  workflow. A custom pipeline adds
  [`actions/e2e-simlock-install`](../../actions/e2e-simlock-install/README.md)
  after its install step.
- **Locally**, after `npm ci` in the e2e project:

  ```sh
  curl -fsSLO https://raw.githubusercontent.com/rnw-community/mobile-ci/v4.11.2/scripts/fetch-e2e-simlock.sh
  bash fetch-e2e-simlock.sh v4.11.2 e2e
  ```

  Pin the same tag your workflows use. Any `npm ci` replaces `node_modules`, so
  run it again after one.

It is TypeScript source: `e2e` compiles it like your tests, so it needs no build.
Its peer dependencies, `@e2e-dev/mobile` and `agent-device`, are your project's.

## Use

```ts
// e2e.config.ts
import { mobile } from '@e2e-dev/mobile';
import { simlockDevices } from '@mobile-ci/e2e-simlock';

import type { E2EConfig } from 'e2e';

const platform = process.env.E2E_PLATFORM === 'android' ? 'android' : 'ios';

export default {
    targets: [
        {
            name: platform,
            engine: mobile({
                platform,
                session: process.env.E2E_SESSION,
                device: simlockDevices({
                    url: process.env.SIMLOCK_URL!,
                    token: process.env.SIMLOCK_TOKEN!,
                    platform,
                    device: platform === 'ios' ? 'iPhone 17 Pro' : 'Pixel 6',
                    tenant: 'my-app'
                })
            }),
            app: { bundleId: process.env.E2E_APP_ID, appPath: process.env.E2E_APP_PATH }
        }
    ],
    workers: Number(process.env.E2E_WORKERS ?? 1),
    retries: Number(process.env.E2E_RETRIES ?? 0)
} satisfies E2EConfig;
```

The workflows set every variable above (`E2E_PLATFORM`, `E2E_SESSION`,
`E2E_APP_ID`, `E2E_APP_PATH`, `E2E_WORKERS`, `E2E_RETRIES`, `SIMLOCK_URL`,
`SIMLOCK_TOKEN`); see the workflow docs'
[E2E suite on simlock](../../docs/workflows/ios-maestro.md#e2e-suite-on-simlock).
An app with one platform names it instead of reading `E2E_PLATFORM`; a repository
with several apps gives each its own target.

### `simlockDevices(options)`

| Option | Required | Default | Meaning |
| --- | --- | --- | --- |
| `url` | yes | | The simlock gateway or worker, without `/v1`. |
| `token` | yes | | The simlock agent token the run leases with. |
| `platform` | yes | | `'ios'` or `'android'`; must match the target's engine. |
| `device` | yes | | A model from the farm's catalog (`GET /v1/catalog?platform=…`). |
| `osVersion` | no | the farm's default | iOS runtime or Android API level, e.g. `'34'`. |
| `imageTag` | no | the farm's choice | Android system image tag, e.g. `'aosp_atd'`. |
| `animations` | no | `'off'` | Android only. `'off'` sets the window, transition and animator scales to 0 once per lease, after the install, as mobile-ci's emulator action did for Maestro. A window still sliding in when a test starts reports a shifted viewport, and gestures then fail with `GESTURE_TRAJECTORY_OUT_OF_BOUNDS`. `'on'` keeps real animations, for lanes that record them. A failed call is a failed device setup: one swap, then the run fails. agent-device 0.21.36 has no iOS equivalent (no simulator reduce-motion setting), so the option throws on an iOS target. |
| `iosScreenshotBackend` | no | agent-device's (simctl) | iOS only: `'runner'` takes every screenshot with the XCTest runner. Its stills have no Dynamic Island, like Maestro's, so baselines Maestro made still match; simctl draws the island into the framebuffer. Any other value, or the option on an Android target, throws. |
| `deviceMode` | no | the farm's (`slim`) | `'full'` leases an unslimmed device: Apple Pay and other PassKit/Wallet flows need one on iOS. `'slim'` or `'full'`; anything else throws. |
| `extraApps` | no | `[]` | `.app`/`.apk` paths installed on every device after the app under test. |
| `ttlMs` | no | `180000` | Lease TTL, renewed every third of it. |
| `installConcurrency` | no | `3` | Big transfers in flight at once on this machine, across the runner and all its workers: app uploads and exec payloads over 1 MiB (E2EDrop files and archives). Each crosses the tunnel, where a request past 100 s ends in a 524. |
| `queueMs` | no | `1200000` | How long a slot waits for a free device before the run fails. |
| `tenant` | no | `'mobile-ci-e2e'` | simlock tenant the leases are filed under; name your project. |

A malformed option throws at config load, naming the option.

What it does for each worker slot:

- **Queues client-side.** Before it asks for a lease, it polls `/v1/status`
  until the farm has a device of the platform free. A request the public tunnel
  cuts off (a 524, or a dropped connection) is released by its own id and asked again, and so is one
  the farm granted on a warm emulator gone from adb (`No Android device with serial`). Any other error
  fails at once, and so does `queueMs` running out or an interrupt.
- **Pins and installs.** It leases one device (`ios-instance` or
  `android-instance`) and names it by simulator UDID or adb serial on every
  command. It uploads the app (at most `installConcurrency` big transfers at once, see below), then each
  of `extraApps`.
- **Sends a cut-off upload again.** An upload the tunnel answers in the farm's place
  (`Invalid upload response: error code: 52x`, a 524 past its 100 s limit) reached no
  install, so it is sent again to the same device: at most three attempts, 15 s ×
  attempt apart, each in its own transfer slot.
- **Swaps once.** Any other failed install releases that device and leases one other.
  It never swaps when the farm itself is down, which includes a tunnel that cut off all three uploads.
- **Fails the run when a slot cannot be set up.** `@e2e-dev/mobile` calls `acquire` once
  per slot and fails the run if any of them rejects, so the provider cannot drop a slot
  and carry on with the rest. The other slots' devices are released, and
  [`rerun-infra-failures`](../../actions/rerun-infra-failures/README.md) gets its one retry.
- **Renews and records.** It renews the lease every `ttlMs / 3` and lists its
  id in `<project>/.e2e/simlock-leases.json`, which mobile-ci's e2e job releases
  on every exit path, a cancel included.
- **Releases.** At the end of the run it releases each lease, and simlock wipes
  the device. A failed release still frees the run.

A loopback relay answers agent-device's `boot` (the farm grants booted devices)
and a bare session `close` (which would end the lease mid-run). It forwards
everything else to the configured gateway only. A read the tunnel cuts off
(`snapshot`, `screenshot`, `get`, `is`, `wait`, `appstate`, `apps`, and a `find`
whose positionals can only name a read) is asked again, at most three times and
2 s × attempt apart, each under its own request id, and logged to stderr. A cut-off
is a dropped connection, or an answer that isn't JSON on a 200 or a 5xx: what
agent-device reports as `Invalid daemon response`. Three cut-offs fail the command,
so a farm that is really down still fails. A command that changes state is never
sent twice, and a `find` it can't prove reads (`find` clicks by default) counts as one. The lease allocate goes through
it too, and gains the target's `deviceMode` on the wire as `params.deviceMode`:
agent-device 0.21.36 and older drop the field from `leases.allocate`, and the
relay rewrite goes away once it passes it (callstack/agent-device#4183). The
farm must map `deviceMode` onto the lease's mode (callstackincubator/simlock#1225).
With `iosScreenshotBackend: 'runner'` the relay also sets
`flags.screenshotCaptureBackend = 'runner'` on every `screenshot` command and drops
`screenshotPixelDensity`: the runner already captures at device density, and the
daemon refuses the two together. That rewrite goes away once agent-device takes
`captureBackend: 'runner'` itself (callstack/agent-device#4184); until then the
farm's agent-device must honour the flag.

Set `deviceMode` per target: give the payments target its own `simlockDevices({
…, deviceMode: 'full' })` and leave the others on the default.

### Screenshots and recordings

- Android lanes that read pixels (screenshots, recordings, store or docs media,
  visual gates) lease a `google_apis` image: `osVersion: '35', imageTag:
  'google_apis'`. On the farm, the API 34 `aosp_atd` image returns all-black
  screenshots (every pixel 0), and its recordings fail with "Android recording
  artifact is not stable". Suites that read only the accessibility tree can keep
  the cheaper `osVersion: '34', imageTag: 'aosp_atd'`.
- iOS stills compared with Maestro-made baselines: set `iosScreenshotBackend:
  'runner'` (no Dynamic Island in the frame).
- Recordings compared with baselines: set `videoTouches: false` on the `mobile()`
  engine. When a recording stops, agent-device redraws its touch indicator onto
  it by default. That re-encode shifts colours (about 17 grey levels lighter on
  dark backgrounds, bt709 tags, constant fps) and breaks a pixel comparison.

### `@mobile-ci/e2e-simlock/steps`

Maestro-compatible steps every Maestro port needs, for any app on either
platform. App-specific steps stay in your suite.

| Helper | What it does |
| --- | --- |
| `byId(screen, id)` | `getByTestId(id).first()`: React Native reports a testID on the host view and its wrapper, and Maestro takes the first. |
| `scrollTo(screen, target, direction?, timeoutMs?)` | Maestro's `scrollUntilVisible`. `direction` is where the content goes (default `'down'`, timeout 20 s); an already visible target does not scroll. |
| `tapUntil(target, next, { attempts?, timeoutMs? })` | Maestro's `retryTapIfNoChange`. It taps `target`, then awaits `next` (the state the tap leads to). It taps again only while `target` is still visible, i.e. the tap was swallowed while a screen settled, up to `attempts` taps (default 2). A target that is gone took the tap, so `next`'s failure is thrown as is. `timeoutMs` bounds each wait. |
| `done({ screen, device })` | Maestro's `tapOn: Done`. It taps the keyboard's own Done key (a `key` with id `Done`), else an accessory bar's Done button, else dismisses the keyboard. Looking for the button alone makes `dismissKeyboard` hang for 30 s on a keyboard whose Done key is the key itself. |
| `scrollToCentered({ screen }, id, { viewportHeight, bottomBandPx?, dragX? })` | Maestro's `centerElement`. It scrolls `id` into view and, if its centre is in the bottom band (default the bottom third), drags the content to bring it to the middle of the viewport, where a tab bar or floating button can't take the tap. The drag starts 40 pt above the band, never on the node, which may be under the overlay. `viewportHeight` is the device's, in `boundingBox()` points. |
| `scrollToMiddle({ screen }, id, { viewportHeight, direction?, tolerancePx?, maxDragPx?, dragX? })` | The same when the node can sit under a header or a tab bar: it scrolls in either `direction` (default `'down'`), then drags at most `maxDragPx` (300) at a time from the middle of the viewport until the node's centre is within `tolerancePx` (150) of it. |
| `scrollAbove({ screen }, id, element, { marginPx?, dragPx?, dragX? })` | Scrolls `id` into view, then drags `dragPx` (250) at a time, starting above `element` (a sticky footer), until the node's bottom edge is `marginPx` (8) above the element's top. An `element` not on screen has nothing to clear. |
| `retry(retries, body)` | Maestro's `retry: { maxRetries }`. It runs `body(attempt)` up to `1 + retries` times, logs each failed attempt and rethrows the last failure. |
| `measureRecording(file)` | How much of a recording repeats itself: `{ frames, durationMs, repeatedFrames, longestStallFrames, longestStallMs }`. See [below](#detecting-a-stalled-recording). Needs `ffmpeg` and `ffprobe` on PATH. |

The three scroll helpers share one drag. A drag the node did not follow for a quarter
of its length means the list is at its end, where it only bounces, so the node stays
where it is and the helper returns. A list still
moving after three drags, or a node with no bounds, fails. `dragX` is the x every
drag runs along, by default the node's centre; set it when that column has switches
or other controls that would take the gesture.

```ts
import { byId, done, scrollToCentered, tapUntil } from '@mobile-ci/e2e-simlock/steps';
import { expect } from 'e2e';

await scrollToCentered({ screen }, 'AccountCard.Cash', { viewportHeight: 874 });
await tapUntil(byId(screen, 'BudgetWidget.EmptyState'), () => expect(byId(screen, 'BudgetCreate.Template.Empty')).toBeVisible({ timeout: 5_000 }));
await byId(screen, 'Amount').fill('12.50');
await done({ screen, device });
```

#### Detecting a stalled recording

An iOS recording from the farm can stall mid-clip: about a second of one stale image,
with monotonic timestamps, so `ffmpeg -xerror` decodes it cleanly and the test stays
green. `measureRecording` compares each frame with the one before, as small grey
thumbnails, since lossy encoding leaves a repeated image a level or two off. A clip
of a scroll that stalled for 50 of its 292 frames reports `longestStallMs: 1140`,
and the five clips of the same run that didn't report at most 281.

A still screen repeats frames too, so the helper only reports. A caller that knows the
clip should move decides what is too long:

```ts
import { measureRecording } from '@mobile-ci/e2e-simlock/steps';

const { longestStallMs } = await measureRecording(clip);
if (longestStallMs > 500) {
    throw new Error(`${clip} stalled for ${longestStallMs} ms: capture it again`);
}
```

### `@mobile-ci/e2e-simlock/exec`

Fixture helpers over simlock's `POST /v1/leases/<id>/exec`, which runs one command
for the leased device only: `simlockApiFromEnv()`, `leaseIdForUdid()`, `exec()` and
`mustExec()`. Both take `(api, leaseId, args, stdin?, tool?)`. `tool` is `'simctl'`
or `'adb'`; left out, it is the one the lease's platform has, asked of the farm once
per lease.

```ts
import { leaseIdForUdid, mustExec, simlockApiFromEnv } from '@mobile-ci/e2e-simlock/exec';

const api = simlockApiFromEnv();
const lease = await leaseIdForUdid(api, device.id);
await mustExec(api, lease, ['shell', 'pm', 'clear', 'com.example.app']);
```

On iOS, the E2EDrop file helpers `writeFile()`, `untar()`, `drop()` and `mustDrop()`
move files onto the simulator. macOS 26 refuses `simctl spawn` of host tools, and the
simulator runtime has no shell, `cp` or `tar`. E2EDrop (`E2E_DROP_APP`, built from
`e2e-drop/`) is a helper app that does the copying. To use it, pass it in `extraApps`.
Nothing installs it by default.

A payload over 1 MiB waits for one of the machine-wide transfer slots app uploads
use: lock files in the OS temp directory, one set per farm, `installConcurrency` of
them. So ten workers dropping a large fixture send at most three at once; a slot
whose holder died is reclaimed. (If two processes reclaim the same dead holder's slot
at the same moment, one extra transfer can run until either finishes.) A single
payload still travels as one request.

`exec()`, `leaseIdForUdid()` and `exec()`'s platform lookup ask again, at most three times and 2 s × attempt apart, when the
connection drops before or during the answer (`fetch failed`, `terminated`) or the
gateway lost its worker (`WORKER_UNREACHABLE`). Every command it sends must be
idempotent. Any other error the gateway answers, and the 11-minute request
timeout, fail at once.
