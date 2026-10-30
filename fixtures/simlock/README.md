# simlock fixtures

Recorded shapes of simlock 0.3.x JSON output that `actions/simlock-lease`
parses, taken from simlock's own documentation
(`website/src/content/docs/docs/using-devices/lease-lifecycle.mdx` and
`getting-started/first-lease.mdx`):

- `grant-ios-slim.json` — a `simlock lease --detach` grant from a worker on
  `drivers.ios.deviceSet: default` (empty `environment`), slim device.
- `grant-ios-full-simlock-set.json` — the same grant from a worker left on the
  default `simlock` device set: `environment.SIMLOCK_IOS_DEVICE_SET` is present,
  which Maestro and `xcodebuild` cannot see (simlock ADR 0048).
- `status-0.3.0.json` — the `daemon` block of `simlock status --json`, whose
  `daemon.version` the action pins.
