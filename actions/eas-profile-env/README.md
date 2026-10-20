# eas-profile-env

Resolves `eas.json` build profiles the way EAS does, following every `extends`
chain: the merged `env` (child wins), the `channel` and the EAS `environment`.
It is the one resolver behind `native-publish.yml`'s plan job,
[`eas-update`](../eas-update/README.md) and
[`eas-channel-fingerprint`](../eas-channel-fingerprint/README.md), so a store
build, the OTA published for it and the fingerprint check that decides between
them all evaluate the app config under the same env.

Fails closed, naming the profile, on: a missing or non-object `eas.json`, an
unknown profile (or an unknown profile in an `extends` chain), an `extends`
cycle, an `env` that is not an object, an env name not matching
`^[A-Za-z_][A-Za-z0-9_]*$`, a non-string or multi-line env value, and a
non-string `extends`, `channel` or `environment`.

## Inputs

| Name       | Required | Default | Description |
| ---------- | -------- | ------- | ----------- |
| `app-dir`  | no       | `'.'`   | Directory holding `eas.json`. |
| `profiles` | **yes**  | —       | Newline-separated build profile names. Duplicates and blank lines are ignored. |

## Outputs

| Name          | Description |
| ------------- | ----------- |
| `resolved`    | JSON object of profile name to `{env, envLines, channel, environment}`. `envLines` is `env` as `KEY=VALUE` lines; `channel` / `environment` are `null` when no level of the chain sets them. |
| `env-lines`   | The profile's env as `KEY=VALUE` lines, when exactly one profile was given. |
| `channel`     | The profile's channel, when exactly one profile was given and it sets one. |
| `environment` | The profile's EAS environment, when exactly one profile was given and it sets one. |

## Example

```yaml
- id: profile
  uses: rnw-community/mobile-ci/actions/eas-profile-env@v4.3.0 # v4.3.0
  with:
      app-dir: apps/mobile
      profiles: production
- run: echo "production publishes to channel $CHANNEL"
  env:
      CHANNEL: ${{ steps.profile.outputs.channel }}
```
