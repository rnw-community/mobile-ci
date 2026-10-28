# eas-channel-fingerprint

Answers "can this commit ship as an OTA on channel X?" before anything is
built or published. For each target it resolves the runtime version this
commit produces with [`ota-runtime-version`](../ota-runtime-version/README.md)
(the project's own `expo-updates`, so every runtime policy resolves exactly as
`eas update` would), under the target's `eas.json` build profile env plus
`env`, and compares it with:

- the latest update for the platform on **every branch the channel serves**
  (`eas channel:view`, then `eas update:list --branch <b> --platform <p>`), and
- the latest **finished build** on the channel (`eas build:list --channel`).

With the default `baseline: update-or-build`, a match on either is `ota`. A
matching **update** only shows that someone published for this runtime, not
that a binary with it is installed; `baseline: build` accepts only a matching
finished EAS build — use it where an OTA nobody can load is a real cost.
`decision=ota` only when every target is `ota`.

**Fail closed.** A channel EAS cannot read (missing, or EAS unreachable), an
update or build listing that fails, and a channel with nothing on it all decide
`native`, never `ota`, with the reason. A missing token or a runtime version
that cannot be resolved fails the step — there is nothing to compare.

Builds made with `eas build --local` are not recorded on EAS, so only the
channel's updates can count for them (and `baseline: build` always decides
`native`): **publish an update to the channel after every `eas build --local`
store build** (e.g. [`eas-update`](../eas-update/README.md) right after the
submit), so the channel's latest update carries the runtime the new binary
has.

The app's dependencies (with `expo-updates`) must be installed.

## Inputs

| Name              | Required | Default  | Description |
| ----------------- | -------- | -------- | ----------- |
| `app-dir`         | no       | `'.'`    | App directory holding the app config, `eas.json` and installed dependencies. |
| `channel`         | no       | `''`     | Channel to compare with. Empty uses `eas-profile`'s channel. |
| `platform`        | no       | `all`    | `all`, `ios` or `android`. |
| `eas-profile`     | no       | `''`     | `eas.json` build profile whose env (`extends` resolved) the runtime version is resolved under, and whose channel is the default. |
| `targets`         | no       | `''`     | JSON array replacing `channel` / `platform` / `eas-profile`: `[{"name", "platform", "channel", "envLines"?, "buildProfile"?}]`, one per target, as `native-publish.yml`'s plan resolves them. |
| `env`             | no       | `''`     | `KEY=VALUE` lines the runtime is resolved under, after the profile env. |
| `unset-env`       | no       | `''`     | Variable names removed before resolving. |
| `baseline`        | no       | `update-or-build` | `update-or-build`, or `build` to require a matching finished EAS build. |
| `eas-cli-version` | no       | `20.5.1` | Pinned eas-cli npm version. |
| `expo-token`      | no       | `''`     | Expo access token. Empty uses `EXPO_TOKEN` from the job env. |

## Outputs

| Name               | Description |
| ------------------ | ----------- |
| `decision`         | `ota` when every target's runtime version matches what its channel serves, `native` otherwise. |
| `reason`           | Why: one sentence per target that decided `native`. |
| `changed-targets`  | Comma-separated targets that decided `native` (platform names without `targets`). |
| `runtime-versions` | JSON object of target (or platform) to the runtime version this commit resolves to — what an OTA must target. |

The step summary carries one row per target: channel, this commit's runtime,
the latest update and build runtimes, and the verdict.

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/eas-channel-fingerprint@v4.5.0 # v4.5.0
  id: fingerprint
  with:
      app-dir: apps/mobile
      eas-profile: production
      expo-token: ${{ secrets.EXPO_TOKEN }}
- if: steps.fingerprint.outputs.decision == 'ota'
  uses: rnw-community/mobile-ci/actions/eas-update@v4.5.0 # v4.5.0
  with:
      app-dir: apps/mobile
      channel: production
      eas-profile: production
      expo-token: ${{ secrets.EXPO_TOKEN }}
```

`native-publish.yml` uses it for `mode: auto` / `ota-only` with
`ota-baseline: eas-channel`.
