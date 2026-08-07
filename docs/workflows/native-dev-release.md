# native-dev-release.yml

`workflow_call` reusable workflow: EAS local development build per enabled
platform, published as a GitHub Release rather than to a store.

Two independent jobs, each gated by its own `enable-*` input:
**ios-dev-release** and **android-dev-release**. Each: computes a
deterministic build number (`run_number.run_attempt`), runs `eas build
--local --profile <build-profile>` for its platform, uploads the artifact,
creates a draft GitHub Release tagged `<tag-prefix>-<platform>-<run_number>`,
attaches the build artifact, publishes the release, then prunes older
published releases under that platform's tag prefix down to `keep-releases`.
A final **status** job aggregates the enabled jobs into a single required
check. Both jobs need `permissions: contents: write` to create/prune
releases.

## Inputs

| Name                     | Required | Default                             | Description |
| --------------------------- | -------- | -------------------------------------- | -------------- |
| `enable-ios`                 | no       | `true`                                  | Run the `ios-dev-release` job. |
| `enable-android`             | no       | `false`                                 | Run the `android-dev-release` job. |
| `ios-runner-labels`          | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the iOS dev-release job. |
| `android-runner-labels`      | no       | `["self-hosted","macOS","ARM64"]`         | JSON array of self-hosted runner labels for the Android dev-release job. Defaults to macOS because Google's Android NDK build tooling used by EAS local builds is x86_64-only on Linux. |
| `app-dir`                    | **yes**  | —                                        | App directory containing `app.json`/`eas.json`. |
| `node-version`               | no       | `22`                                     | Node version for `actions/setup-node`. |
| `install-command`            | no       | `yarn install --immutable`                | JS dependency install command. |
| `enable-corepack`            | no       | `true`                                    | Run `corepack enable` before install. |
| `build-command`              | no       | `''`                                      | Optional workspace JS build command run at repo root before the dev build. |
| `eas-cli-version`            | no       | `20.5.1`                                  | Pinned `eas-cli` npm version invoked via `npx eas-cli@<version>`. |
| `build-profile`              | no       | `development`                             | EAS build profile (`eas.json` `build.<profile>`) used for both platforms. |
| `tag-prefix`                 | no       | `dev`                                     | Release tag prefix. Tags are created as `<tag-prefix>-ios-<run_number>` and `<tag-prefix>-android-<run_number>`. |
| `keep-releases`              | no       | `5`                                       | Number of newest published releases (per platform tag) to keep; older ones are pruned. |
| `asc-key-path`               | no       | `''`                                       | Optional path, relative to `app-dir`, the App Store Connect API key (`.p8`) is written to and removed from. Only used when the `ASC_API_KEY` secret is set. Leave empty (default) to write the key under `$RUNNER_TEMP` instead, keeping it out of the `eas build --local` archive; set it only when `eas.json` requires the key at a specific `app-dir`-relative location. |
| `build-timeout-minutes`      | no       | `120`                                     | Dev-release job timeout (both platforms). |

## Secrets

| Name                | Required | Description |
| ---------------------- | -------- | -------------- |
| `EXPO_TOKEN`             | no*      | Expo access token, required by both dev-release jobs. |
| `ASC_API_KEY`            | no       | Optional App Store Connect API key contents (`.p8`), used by `ios-dev-release` when the development profile needs automatic device/credential management. |
| `ASC_KEY_ID`             | no       | App Store Connect API key ID matching `ASC_API_KEY`. Exported to the build step as `EXPO_ASC_KEY_ID`; set alongside `ASC_API_KEY`/`ASC_ISSUER_ID` so EAS can resolve the key non-interactively. |
| `ASC_ISSUER_ID`          | no       | App Store Connect API key issuer ID matching `ASC_API_KEY`. Exported to the build step as `EXPO_ASC_ISSUER_ID`; set alongside `ASC_API_KEY`/`ASC_KEY_ID` so EAS can resolve the key non-interactively. |

\* `EXPO_TOKEN` is declared optional at the `workflow_call` level, but each
enabled dev-release job validates it is present at the start of the job and
fails fast with a clear error if it is missing. Pass secrets via `secrets:
inherit` or an explicit `secrets:` block in the caller workflow.

## Permissions

The caller workflow needs `permissions: contents: write` (or an equivalent
token) — both jobs create and prune GitHub Releases and tags.

## Example

```yaml
# .github/workflows/native-dev-release.yml
name: Native dev release
on:
    workflow_dispatch:
    push:
        branches: [main]
permissions:
    contents: write
jobs:
    dev-release:
        uses: rnw-community/mobile-ci/.github/workflows/native-dev-release.yml@main
        with:
            app-dir: apps/mobile
            enable-ios: true
        secrets: inherit
```
