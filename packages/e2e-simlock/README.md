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
  curl -fsSLO https://raw.githubusercontent.com/rnw-community/mobile-ci/v4.9.0/scripts/fetch-e2e-simlock.sh
  bash fetch-e2e-simlock.sh v4.9.0 e2e
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
| `extraApps` | no | `[]` | `.app`/`.apk` paths installed on every device after the app under test. |
| `ttlMs` | no | `180000` | Lease TTL, renewed every third of it. |
| `installConcurrency` | no | `3` | App uploads in flight at once. |
| `queueMs` | no | `1200000` | How long a slot waits for a free device before the run fails. |
| `tenant` | no | `'mobile-ci-e2e'` | simlock tenant the leases are filed under; name your project. |

A malformed option throws at config load, naming the option.

What it does for each worker slot:

- **Queues client-side.** Before it asks for a lease, it polls `/v1/status`
  until the farm has a device of the platform free. A request the public tunnel
  cuts off (a 524) is released by its own id and asked again. Any other error
  fails at once, and so does `queueMs` running out or an interrupt.
- **Pins and installs.** It leases one device (`ios-instance` or
  `android-instance`) and names it by simulator UDID or adb serial on every
  command. It uploads the app (at most `installConcurrency` at once), then each
  of `extraApps`.
- **Swaps once.** A failed install releases that device and leases one other.
  It never swaps when the farm itself is down.
- **Renews and records.** It renews the lease every `ttlMs / 3` and lists its
  id in `<project>/.e2e/simlock-leases.json`, which mobile-ci's e2e job releases
  on every exit path, a cancel included.
- **Releases.** At the end of the run it releases each lease, and simlock wipes
  the device. A failed release still frees the run.

A loopback relay answers agent-device's `boot` (the farm grants booted devices)
and a bare session `close` (which would end the lease mid-run). It forwards
everything else to the configured gateway only.

### `@mobile-ci/e2e-simlock/exec` (iOS)

Fixture helpers over simlock's `POST /v1/leases/<id>/exec`, which runs `simctl`
for the leased simulator only: `simlockApiFromEnv()`, `leaseIdForUdid()`,
`exec()`, `mustExec()`, and the E2EDrop file helpers `writeFile()`, `untar()`,
`drop()` and `mustDrop()`. macOS 26 refuses `simctl spawn` of host tools, and the
simulator runtime has no shell, `cp` or `tar`. E2EDrop (`E2E_DROP_APP`, built
from `e2e-drop/`) is a helper app that does the copying. To use it, pass it in
`extraApps`. Nothing installs it by default.
