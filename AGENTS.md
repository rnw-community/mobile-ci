# AGENTS.md

Canonical instructions for AI agents (and humans) working with this repo.
This repo is a monorepo of composite GitHub Actions (`actions/*`) and
reusable `workflow_call` workflows (`.github/workflows/*`) for React
Native / Expo mobile CI on self-hosted runners.

Two audiences below: agents changing this repo itself (A), and agents
wiring this repo's actions/workflows into a consumer app repo (B). Read
the section that matches your task; skip the other.

## A. Working ON this repo

### Repo map

- `actions/<name>/action.yml` — one composite action per directory.
- `actions/<name>/README.md` — that action's input/output table + one example.
- `.github/workflows/*.yml` — reusable `workflow_call` workflows, plus
  `self-test.yml` (CI lint/scan) and `pr-closed-cleanup.yml` (this repo's own
  consumer of `pr-closed-cleanup-reusable.yml`).
- `docs/workflows/<name>.md` — full input/secret/permission reference per
  reusable workflow, one file per workflow in `.github/workflows/`, each with a
  `### Minimal` and a `### Full` example.
- `docs/examples/` — complete caller workflows for four app shapes (public
  Expo, private multi-brand Expo, pure Swift/Xcode, RN packages monorepo).
- `docs/self-hosted-runners.md` — self-hosted host provisioning guide (macOS
  Xcode pools, x86_64 Linux KVM hosts, `linux-aarch64` Redroid hosts, prewarm
  manifest format).
- `docs/repack.md` — why a pull request no longer compiles native code, the
  native key's correctness boundary, the `fingerprint.config.js` contract, and
  the permissions every consumer's calling job needs.
- `fixtures/` — minimal inputs the tests and `self-test.yml` run this repo's
  own actions against (a two-test Swift Package for `swift-test`, `simctl`
  listings for `simulator-lease`, path-to-test maps for
  `xcodebuild-affected-tests`, budgie's original media scripts, which are
  the pixel-parity reference for `compose-media`, and recorded eas-cli
  `--json` output per eas-cli version under `eas-cli/` for the EAS Update
  parsers).
- `tests/` — `run-tests.sh` plus one `<action>_test.sh` per action under test.
  Each suite extracts the step's `run:` body from the parsed `action.yml` and
  executes it against `fixtures/` with stubbed binaries, so no test duplicates
  the shell it is testing and a renamed step fails rather than drifts.
  `self-test.yml`'s `unit-tests` job runs them and shellchecks every extracted
  step script.
- `profiles/ci.json` — the simslim profile every simulator, in CI and locally,
  is slimmed against; the actions resolve `slim-profile: bundled` to it.
- `scripts/slim-simulator.sh` — sourceable `slim_simulator` /
  `slim_booted_simulators` helpers consumers fetch at a pinned tag instead of
  keeping a copy.
- `scripts/media/` — `frame-device.sh` (sourceable frameit framing primitives),
  `compose-web-media.sh` and `compose-web-clips.sh`, plus their shared
  `media-common.sh`. The `compose-media` action wraps them; consumers can also
  run them locally or fetch them at a pinned tag.
- `CONTRIBUTING.md` — versioning, marketplace stance, third-party pinning,
  self-references, local validation, action-change checklist.
- `RELEASE.md` — the exact tag-and-publish procedure for cutting `vX.Y.Z`.
- `SECURITY.md` — vulnerability reporting, self-hosted-runner threat model.

### Hard conventions

- Every action under `actions/` is a **composite** action (`runs: using:
  composite`). Do not introduce a Docker or JavaScript action.
- Inputs reach `run:` scripts **only** via step-level `env:` blocks. Never
  interpolate `${{ inputs.* }}` / `${{ ... }}` directly inside a `run:`
  script body — always map it to an env var first, then reference the env
  var in the shell. This applies to every `run:` step in every action and
  workflow.
- **Fail closed.** A detection, parse, or validation error must fail the
  step/job, never silently report success or "unaffected"/"skip". See
  `turbo-affected` and `expo-repack` for the pattern.
- Every third-party `uses:` (anything not `rnw-community/mobile-ci/...`) is
  pinned to a full commit SHA with a trailing `# vX.Y.Z` comment. Dependabot
  opens the bump PRs; never hand-edit a SHA without updating its comment.
- Self-references (this repo's own actions/workflows calling each other) use
  the full `rnw-community/mobile-ci/actions/<name>@<ref>` /
  `rnw-community/mobile-ci/.github/workflows/<name>.yml@<ref>` form, never a
  relative `./actions/<name>` path — a relative path only resolves against
  the *caller's* checkout, not this repo. See
  [CONTRIBUTING.md#self-references](CONTRIBUTING.md#self-references).
- **A new action is pinned to the UPCOMING release tag**, never the current
  one: the current tag does not contain it, and `self-test.yml`'s
  `self-reference-resolution` job fails any self-reference whose tag lacks the
  referenced action or workflow (RELEASE.md's tag-known-in-advance rule).
- Any PR that adds, removes, renames, or changes the default of an
  `action.yml` input/output must update that action's `README.md`
  input/output table **in the same PR**.
- Any PR that changes a reusable workflow's inputs must update the matching
  `docs/workflows/<name>.md` **in the same PR**.
- Documented calls cannot drift: `tests/docs-examples_test.sh` resolves every
  `rnw-community/mobile-ci/...@<ref>` in `docs/examples/` and in the docs'
  yaml blocks to the file at this commit and fails on an undeclared input or
  secret; the examples and each workflow doc's Minimal/Full blocks must also
  pass every required input, pin `@vX.Y.Z # vX.Y.Z`, and grant every scope the
  called workflow's jobs request. Renaming an input means fixing its docs.
- No code comments in `action.yml` beyond what a descriptive step `name:`
  could not already convey — prefer renaming over explaining.
- Keep `run:` blocks POSIX-shell-compatible and `shellcheck`-clean.

### Required validation before claiming done

Run, and confirm clean, before saying a change is finished (see
`self-test.yml` for exact pinned versions/commands):

```bash
actionlint -color
actionlint -color docs/examples/*/*.yml
tests/run-tests.sh
shellcheck <changed .sh files / run: blocks extracted as needed>
zizmor --config .github/zizmor.yml .github/workflows actions
```

Locally, `actionlint` can hang on `store-screenshots.yml`; lint the files you
changed one at a time under `timeout` (CI runs the whole tree).

A change to an action's `run:` logic comes with a case in `tests/`, and the
case is proven red before the fix: every step script there is extracted from
`action.yml` at run time, so a test that passes against the unfixed action is
testing nothing.

`actionlint` also schema-checks any `actions/*/action.yml` referenced by a
local relative path from a workflow step. `self-test.yml`'s
`dry-lint-local-refs` job additionally rewrites the reusable workflows'
self-references to relative paths in a scratch copy to lint their composite
schemas too — reproduce that locally with the same `sed` substitution before
running `actionlint` if you touched a reusable workflow's inputs.

### Consumer validation on the fleet

The rules, each learned from a release that shipped broken:

- **Fleet-validate before release** — static checks and green unit tests are
  not evidence that a workflow works.
- **One fleet run at a time** — the self-hosted pools are shared and
  serialized; parallel dispatches queue, cancel each other, or starve other
  repositories.
- **Read the artifacts**, not the check marks.

Static checks prove a change is well-formed, not that it works. Every change
that alters runtime behaviour — action `run:` logic, workflow wiring, new or
changed inputs, pinned third-party action bumps — **must be validated against
`vitalyiegorov/suuudokuuu` on the real fleet before it is released**, because
that repo consumes every reusable workflow end to end (e2e, cache seeding,
dev release, store publish, screenshots).

Procedure:

1. Push the branch, then pin suuudokuuu's callers to the branch head SHA
   (`...@<sha> # <branch>`) in a scratch branch of that repo.
2. Run the pipelines the change can affect, **one fleet run at a time**, via
   `workflow_dispatch` (e.g. `gh workflow run mobile-e2e.yml --ref
   <branch>`): `mobile-e2e.yml` and, where relevant, `seed-native-cache.yml`,
   `native-dev-release.yml`, `native-publish.yml`. suuudokuuu's
   `mobile-e2e.yml` push trigger is scoped to `branches: [main]`, so a push
   to a scratch branch never runs it — `workflow_dispatch` is the only way to
   exercise it off `main`.
3. Read the artifacts, not just the check marks. Several defects have shipped
   green: an `aab` no tester could install, an App Store Connect key that was
   written but never exported, a Maestro workspace config silently dropped.
   Confirm the *effect* — the artifact's extension, the absence of a fallback
   log line, the screenshot actually collected.
4. Only then open the release PR and move the tag.

A change that cannot be exercised by suuudokuuu (a driver it does not use, a
platform it does not ship) must say so explicitly in its PR body, and name
whatever validation was done instead.

suuudokuuu is a React Native / Expo consumer and exercises **none** of the
native-Swift lane (`xcode-cache`, `swift-test`, `simulator-lease`,
`xcodebuild-test`, `apple-signing`, `xcode-archive-upload`, `swift-ios.yml`).
That lane's consumer of record is `vitalyiegorov/pony-labirinth`, a pure
Xcode/SwiftPM app with no Node, Expo or CocoaPods; validate changes to it there,
plus `self-test.yml`'s manual `fleet-swift-self-test` job for the two actions
`fixtures/swift-package` can cover on its own.

### PR review etiquette

**ALWAYS address every bot comment on a PR (CI bots, review bots,
Dependabot, code scanners). If a bot comment is valid — fix it. If it is not
valid — reply to that comment explaining why it does not apply; never leave
a bot comment unanswered and never silently ignore one. Findings a review
bot marks vital/critical/high severity (e.g. Macroscope "High"/"Critical",
CodeRabbit "Critical"/"Major" correctness/security categories) MUST be fixed
in the same PR, never merely replied to or deferred, unless the finding is
factually wrong — in which case the reply must cite concrete evidence
(file/line, command output, or spec reference) proving why. Lower-severity
and style findings may be fixed or answered with reasoning.**

### Versioning

Self-references pin to the exact release tag (`@vX.Y.Z # vX.Y.Z`);
consumers pin to an exact tag or a full commit SHA, or float on the
sliding major tag (`v4` is current) at their own risk. The exact
tag-and-publish procedure, including moving the floating major tag of the
release being cut — and only that major's, so `v1` stays frozen — lives in
[RELEASE.md](RELEASE.md) — never move a release tag manually outside that
procedure.

## B. USING this repo from a consumer project

**Start from [docs/examples/](docs/examples/README.md)** — complete, CI-checked
caller workflows for a public Expo app, a private multi-brand Expo app, a pure
Swift/Xcode app and an RN packages monorepo. Then read
`docs/workflows/<name>.md` for every workflow you wire: each has the full
input/secret/permission tables and a Minimal and a Full example. Never guess
an input name or default.

**A pull request does not compile native code by default.** The e2e and
screenshot workflows compute a native key on Linux, fetch the base binary the
warm-up published for it, and repack it with this commit's JavaScript; only a
key with no published base reaches a Mac or Gradle. Read
[docs/repack.md](docs/repack.md) before wiring or debugging any Expo pipeline.

Prefer the **reusable workflows** over composing raw actions unless you
already have a working pipeline and are adopting one piece at a time (à la
carte tier — see [README.md](README.md#pick-your-tier)).

### Workflows and the permissions their calling job must grant

A reusable workflow can only narrow its caller's token, and GitHub refuses to
start a run whose called job requests more than the calling job granted —
even a skipped job. Put this `permissions:` block on the job with `uses:`:

| Workflow | Purpose | Calling job `permissions:` |
| --- | --- | --- |
| `ios-maestro.yml` | iOS Maestro e2e (`ios-driver: local` or `device-cloud`; `tolerate-test-failures` for a time-boxed quarantine) | `contents: read`, `packages: write`, `actions: read` |
| `android-maestro.yml` | Android Maestro e2e (`android-driver: avd` default on x86_64 KVM, `redroid` on `linux-aarch64`, or `device-cloud`) | `contents: read`, `packages: write`, `actions: read` |
| `seed-native-cache.yml` | The warm-up: publishes the base binary pull requests repack. Default-branch push with a `paths:` filter | `contents: read`, `packages: write`, `actions: read` |
| `store-screenshots.yml` | Store screenshot capture matrix + gated fastlane upload | `contents: read`, `packages: write`, `actions: read` |
| `native-dev-release.yml` | Dev build to a GitHub Release (`distribution: github-release`) or EAS internal distribution (`eas`); `build-location: local` or `cloud` | `contents: write` (+ `pull-requests: write` with `pr-comment: true`) |
| `native-publish.yml` | Signed store publish (`eas build --local` + `eas submit`); `credentials-source: secrets\|eas`, `record-scope` per brand call, `mode: auto` with `ota-baseline: github-release\|eas-channel` | `contents: read` (+ `contents: write` for the store build record, + `actions: read` for `build-number: auto` in a private repo) |
| `expo-ota-preview.yml` | Pull-request OTA preview + sticky comment; `ota-backend: github-release\|eas` | `contents: write`, `pull-requests: write` |
| `eas-channel-cleanup-reusable.yml` | Deletes a closed PR's EAS channel and branch; sweeps idle channels | `contents: read` |
| `pr-closed-cleanup-reusable.yml` | Cancels a closed PR's runs; opt-in deletes its GitHub Release previews | `actions: write` (+ `contents: write` with `ota-preview-release-tag-prefix`) |
| `preview-sweep-reusable.yml` | Scheduled, dry-run-by-default sweep of stale GitHub Release previews | `contents: write`, `pull-requests: read` |
| `expo-fingerprint-guard.yml` | Fails a PR that moves the native runtime fingerprint, unless labelled | `contents: read`, `pull-requests: read` |
| `assert-distinct-fingerprints.yml` | Release pre-flight: two app ids must not share a native key | `contents: read` |
| `swift-ios.yml` | Pure Swift/Xcode build, sharded tests, opt-in TestFlight publish | `contents: write` (always — its `publish` job requests it) |
| `expo-base-plan.yml` | Shared repack decision the e2e/screenshot/warm-up workflows call; not called directly | — |

**EAS Update outside these workflows** — compose the actions: `eas-update`
publishes to a channel; `eas-channel-fingerprint` decides `ota|native` against
what a channel serves; `eas-profile-env` resolves an `eas.json` profile's env,
channel and environment; `ota-runtime-version` is the one runtime-version
source every OTA path uses (the project's own `expo-updates`).
`native-fingerprint` is a native-build cache key only, never a runtime version.

### Choosing the OTA backend

- **`github-release`** (`expo-ota-preview.yml` default): tokenless, but
  **public repositories only** (devices download release assets anonymously)
  and **previews for development builds only** — no code signing, rollout or
  rollback. Clean up with `pr-closed-cleanup-reusable.yml`
  (`ota-preview-release-tag-prefix`) + `preview-sweep-reusable.yml`.
- **`eas`**: needs `EXPO_TOKEN`; any repository; the only choice for
  production channels. Clean up with `eas-channel-cleanup-reusable.yml`.
- Production updates: `eas-update` in a job with `environment:` (required
  reviewers), gated on `native-publish.yml`'s `decision` output. A job that
  calls a reusable workflow cannot name an `environment:`, so environment
  secrets never reach one.

### Maestro flow-file convention

Runnable Maestro flows are top-level `*.flow.yaml` files directly inside
whatever directory you pass as `flows-dir`. Subflows, fixtures, and
capture-only flows live in **subdirectories** of `flows-dir` and are never
auto-discovered or run standalone by the sharding logic.

### Secrets

Pass secrets explicitly, never `secrets: inherit` (that hands every repository
secret to a third-party workflow).

- No secrets: `ios-maestro.yml`, `android-maestro.yml`,
  `seed-native-cache.yml`, `pr-closed-cleanup-reusable.yml`,
  `preview-sweep-reusable.yml`, `expo-fingerprint-guard.yml`,
  `assert-distinct-fingerprints.yml`.
- Optional masked env: `build-secrets-env` (e2e, screenshots, warm-up; only a
  digest enters the native key, so pass the warm-up the same secret) and
  `maestro-secrets-env` (e2e, screenshots); `device-cloud-api-key` for the
  `device-cloud` drivers.
- `native-publish.yml`: `EXPO_TOKEN`; `ASC_API_KEY` + `ASC_KEY_ID` +
  `ASC_ISSUER_ID` (iOS) and `GOOGLE_SERVICE_ACCOUNT_JSON` (Android), optional
  with `credentials-source: eas`; optional `EAS_EXTRA_ENV`.
- `native-dev-release.yml`: `EXPO_TOKEN`; optional ASC key set and
  `EAS_EXTRA_ENV`.
- `expo-ota-preview.yml` with `ota-backend: eas`: `EXPO_TOKEN` (optional
  `EAS_EXTRA_ENV`). `eas-channel-cleanup-reusable.yml`: `EXPO_TOKEN`.
- `store-screenshots.yml` upload: the ASC key set; `swift-ios.yml` publish:
  `apple-certificate-base64`, `apple-certificate-password`,
  `apple-profile-base64`, `asc-key-base64`, `asc-key-id`, `asc-issuer-id`.

Each workflow's `docs/workflows/<name>.md#secrets` says which job requires
which secret and how it fails fast when one is missing.

### Pinning

Pin to an exact `vX.Y.Z` tag or a full commit SHA, with a trailing
`# comment`. A floating major tag (`v4`) exists for consumers who accept
moving with the latest release of that major; `@main` can change without a
deprecation window.

```yaml
uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v4.2.0 # v4.2.0
```

### Self-hosted runner prerequisites

Every workflow above assumes a self-hosted fleet: macOS Xcode pools for iOS,
and one of two Android host shapes — x86_64 Linux with `/dev/kvm` and an
Android SDK for the default `avd` driver (no Docker daemon, no privileged
container, no kernel module), or `linux-aarch64` with Docker,
`binder_linux`, and privileged containers allowed for the `redroid` driver.
The `avd` shape is what `android-maestro.yml`'s default `runner-labels`
name; the `redroid` shape is selected by passing `android-driver: redroid`
together with `runner-labels` for that pool. `android-maestro.yml`'s test
job fails closed on the mismatch rather than timing out. Read
[docs/self-hosted-runners.md](docs/self-hosted-runners.md) before wiring a
pipeline — it covers exact Xcode install layout, which pool a job belongs
on, KVM/emulator prerequisites, the `binder_linux` kernel module,
privileged-container requirements, and the Redroid prewarm manifest format
that avoids paying for a cold `docker pull` + first-boot on every shard.

### Minimal consumer snippet

```yaml
# .github/workflows/e2e.yml (in your app repo)
name: E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [main]
jobs:
    ios:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v4.2.0 # v4.2.0
        with:
            targets: >-
                [{"name":"app","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":"npx expo prebuild -p ios"}]
            flows-dir: apps/mobile/e2e/flows
    android:
        permissions:
            contents: read
            packages: write
            actions: read
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@v4.2.0 # v4.2.0
        with:
            targets: >-
                [{"name":"app","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":"npx expo prebuild -p android"}]
            flows-dir: apps/mobile/e2e/flows
```

Add the warm-up ([docs/examples/public-expo-app/warm-up.yml](docs/examples/public-expo-app/warm-up.yml))
with the same `fingerprint-config` / `fingerprint-env`, or every pull request
whose native key moved compiles natively.
