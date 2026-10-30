# simlock-lease

Leases one iOS simulator from the host's
[simlock](https://github.com/callstackincubator/simlock) worker for one job,
and hands it back on the paired `mode: release` call. It exists for
**host-mode** Macs: runners that run jobs directly on the Mac instead of in a
Tart VM, so a host is no longer capped at Apple's two concurrent macOS VMs and
several Maestro shards share it. Each shard holds its own simulator, which
simlock created, booted, slimmed and verified, and wipes for the next lease
when it comes back. See
[docs/self-hosted-runners.md](../../docs/self-hosted-runners.md#host-mode-macs-with-a-simlock-worker).

`ios-maestro.yml` calls it for you with `simulator-provider: simlock`; call it
directly only when composing `run-maestro-ios` yourself.

## How the lease is held

A composite action cannot keep a process running across steps, and a held
`simlock lease` releases its device as soon as its parent shell exits. The
acquire call therefore takes a **detached** lease:

```sh
simlock --local status --json            # the worker's daemon.version must equal simlock-version
simlock --local lease --platform ios --detach --ttl <ttl> \
    --agent-id github-actions.<repo>.<run id>.<attempt>.<job>.<runner> \
    --mode <device-mode> [--device <device>] [--os <os>] [--timeout <queue-timeout>]
simlock --local release <lease id>       # the release call, as the same requester
```

Nothing renews a detached lease, so `ttl` must cover the whole job: set it to
at least the job's `timeout-minutes` (`ios-maestro.yml` uses
`test-timeout-minutes`). A job that dies before its release step returns the
device one TTL after the grant. The requester identity is unique per job
attempt and runner, so simlock's one-lease-per-requester limit never makes
two shards on one host wait for each other.

## Fail closed

- No `simlock` on PATH, or a worker on another version than `simlock-version`:
  the step fails before leasing. simlock bumps its protocol with no
  compatibility shim, so the worker and the pin move together.
- The worker keeps its simulators in its own device set (the grant carries
  `SIMLOCK_IOS_DEVICE_SET`): Maestro and `xcodebuild` cannot find the UDID
  there (simlock ADR 0048), so the lease is handed back and the step fails.
  Set `simlock config set drivers.ios.deviceSet default` on the worker.
- `NO_CAPACITY`, `QUEUE_TIMEOUT`, a lost or unstartable daemon, and a release
  that fails are annotated `Infrastructure failure: simlock ...`, which
  [`rerun-infra-failures`](../rerun-infra-failures/README.md) re-runs. An
  unknown model, a missing runtime or a bad request is annotated
  `simlock lease refused with <code>` and is not retried.
- A `slim` request on a runtime older than iOS 18.5 is granted a `full`
  device; the step warns and `device-mode` reports `full`.
- `release` with no lease file warns and succeeds (the acquire never got a
  grant); a lease simlock already ended (`UNKNOWN_LEASE`) warns; any other
  release failure fails the step and keeps the lease file.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `mode` | `acquire` | `acquire` or `release`. |
| `device` | `''` | Exact model as `simlock catalog` prints it, e.g. `iPhone 17`. Empty lets simlock pick its default phone. |
| `os` | `''` | Exact iOS version (`26.2`) or a range (`>=18 <27`). Empty takes the newest installed runtime. |
| `device-mode` | `slim` | `slim` (best effort; `full` on a runtime older than 18.5) or `full`. |
| `ttl` | `90m` | Detached lease lifetime as a simlock duration (`90m`, `2h`). At least the job's `timeout-minutes`; simlock caps it at `lease.maxTtlMs` (4h by default). |
| `queue-timeout` | `30m` | How long to wait in the worker's queue. Empty waits without limit. |
| `simlock-version` | `0.3.0` | Exact version the host's worker must run. |
| `lease-file` | `''` | Lease record. Empty writes `$RUNNER_TEMP/simlock-lease-<lease id>.json` on acquire and sweeps every `simlock-lease-*.json` under `$RUNNER_TEMP` on release. |

## Outputs

| Output | Description |
| --- | --- |
| `udid` | UDID of the leased simulator, in Xcode's own device set. |
| `lease-id` | The simlock lease id. |
| `device-mode` | `slim` or `full`: the mode the device really has. |
| `device` | Model of the leased simulator. |
| `os` | iOS version of the leased simulator. |
| `lease-file` | The lease file the release call reads back. |

## Example

```yaml
- name: Lease a simulator
  id: simlock
  uses: rnw-community/mobile-ci/actions/simlock-lease@v4.8.0 # v4.8.0
  with:
      device: iPhone 17
      ttl: 75m
- uses: rnw-community/mobile-ci/actions/run-maestro-ios@v4.8.0 # v4.8.0
  with:
      app-path: build/MyApp.app
      app-id: com.example.app
      flows-dir: e2e/flows
      simulator-udid: ${{ steps.simlock.outputs.udid }}
- name: Release the simulator
  if: always()
  uses: rnw-community/mobile-ci/actions/simlock-lease@v4.8.0 # v4.8.0
  with:
      mode: release
      lease-file: ${{ steps.simlock.outputs.lease-file }}
```
