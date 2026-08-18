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
  reusable workflow, one file per workflow in `.github/workflows/`.
- `docs/self-hosted-runners.md` — self-hosted host provisioning guide (macOS
  Xcode pools, Linux `linux-aarch64` Redroid hosts, prewarm manifest format).
- `CONTRIBUTING.md` — versioning, marketplace stance, third-party pinning,
  self-references, local validation, action-change checklist.
- `RELEASE.md` — the exact tag-and-publish procedure for cutting `v1.x.y`.
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
  `turbo-affected` and `repack-app` for the pattern.
- Every third-party `uses:` (anything not `rnw-community/mobile-ci/...`) is
  pinned to a full commit SHA with a trailing `# vX.Y.Z` comment. Dependabot
  opens the bump PRs; never hand-edit a SHA without updating its comment.
- Self-references (this repo's own actions/workflows calling each other) use
  the full `rnw-community/mobile-ci/actions/<name>@<ref>` /
  `rnw-community/mobile-ci/.github/workflows/<name>.yml@<ref>` form, never a
  relative `./actions/<name>` path — a relative path only resolves against
  the *caller's* checkout, not this repo. See
  [CONTRIBUTING.md#self-references](CONTRIBUTING.md#self-references).
- Any PR that adds, removes, renames, or changes the default of an
  `action.yml` input/output must update that action's `README.md`
  input/output table **in the same PR**.
- Any PR that changes a reusable workflow's inputs must update the matching
  `docs/workflows/<name>.md` **in the same PR**.
- No code comments in `action.yml` beyond what a descriptive step `name:`
  could not already convey — prefer renaming over explaining.
- Keep `run:` blocks POSIX-shell-compatible and `shellcheck`-clean.

### Required validation before claiming done

Run, and confirm clean, before saying a change is finished (see
`self-test.yml` for exact pinned versions/commands):

```bash
actionlint -color
shellcheck <changed .sh files / run: blocks extracted as needed>
zizmor --config .github/zizmor.yml .github/workflows actions
```

`actionlint` also schema-checks any `actions/*/action.yml` referenced by a
local relative path from a workflow step. `self-test.yml`'s
`dry-lint-local-refs` job additionally rewrites the reusable workflows'
self-references to relative paths in a scratch copy to lint their composite
schemas too — reproduce that locally with the same `sed` substitution before
running `actionlint` if you touched a reusable workflow's inputs.

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
sliding `v1` tag at their own risk. The exact tag-and-publish procedure,
including moving the floating `v1` tag, lives in
[RELEASE.md](RELEASE.md) — never move a release tag manually outside that
procedure.

## B. USING this repo from a consumer project

Prefer the **reusable workflows** over composing raw actions unless you
already have a working pipeline and are adopting one piece at a time (à la
carte tier — see [README.md](README.md#pick-your-tier)):

- `ios-maestro.yml` — iOS Maestro e2e.
- `android-maestro.yml` — Android Maestro e2e (Redroid driver by default).
- `seed-native-cache.yml` — proactively warms the native-app cache.
- `native-publish.yml` — signed store publish (`eas build --local` + `eas submit`).
- `native-dev-release.yml` — dev-profile build published to a GitHub Release.
- `store-screenshots.yml` — fleet-native store screenshot capture matrix
  (iOS simulators + Android Redroid containers) driven either by a Maestro
  flow-per-scene convention (`capture-mode: flows`, iOS-only) or by a
  deep-link/flow scene manifest with a per-cell seed hook
  (`capture-mode: direct`, required for Android), with a gated fastlane
  upload job and optional App Store slot-resolution validation.
- `pr-closed-cleanup-reusable.yml` — cancels zombie runs on a closed PR's branch.

Full input/secret/permission tables and a copy-pasteable example live in
`docs/workflows/<name>.md` for each workflow above — read the doc for the
workflow you are wiring, do not guess at input names or defaults.

**Pin to an exact `vX.Y.Z` tag or a full commit SHA with a trailing
`# comment`.** A floating `v1` tag exists for consumers who accept moving
with the latest release (see [README.md](README.md) and
[RELEASE.md](RELEASE.md)); `@main` can change without a deprecation window.

```yaml
uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@v1.6.1 # v1.6.1
```

### Maestro flow-file convention

Runnable Maestro flows are top-level `*.flow.yaml` files directly inside
whatever directory you pass as `flows-dir`. Subflows, fixtures, and
capture-only flows live in **subdirectories** of `flows-dir` and are never
auto-discovered or run standalone by the sharding logic.

### Secrets

- `ios-maestro.yml`, `android-maestro.yml`, `seed-native-cache.yml`,
  `pr-closed-cleanup-reusable.yml` need **no secrets at all** — no
  `EXPO_TOKEN`, no signing credentials.
- `native-publish.yml` (opt-in secrets, only for the platforms you enable):
  `EXPO_TOKEN`, `ASC_API_KEY` (iOS), `GOOGLE_SERVICE_ACCOUNT_JSON` (Android),
  `EAS_EXTRA_ENV` (optional, masked `KEY=VALUE` env for `eas build`/`eas
  submit`, e.g. `EXPO_APPLE_APP_SPECIFIC_PASSWORD`).
- `native-dev-release.yml` (opt-in secrets): `EXPO_TOKEN` (required by both
  enabled dev-release jobs), `ASC_API_KEY` (optional, iOS only),
  `EAS_EXTRA_ENV` (optional, masked `KEY=VALUE` env for `eas build`).

See each workflow's `docs/workflows/<name>.md#secrets` for which job
requires which secret and how the job fails fast when one is missing.

### Self-hosted runner prerequisites

Every workflow above assumes a self-hosted fleet: macOS Xcode pools for iOS,
and Linux `linux-aarch64` + Docker + `binder_linux` for the Redroid Android
driver. Read [docs/self-hosted-runners.md](docs/self-hosted-runners.md)
before wiring a pipeline — it covers exact Xcode install layout, the
`binder_linux` kernel module, privileged-container requirements, and the
Redroid prewarm manifest format that avoids paying for a cold
`docker pull` + first-boot on every shard.

### Minimal consumer snippet

```yaml
# .github/workflows/ios-maestro.yml (in your app repo)
name: iOS Maestro E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [main]
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/ios-maestro.yml@<full-commit-sha>
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","workspace":"MyApp.xcworkspace","scheme":"MyApp","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
```

```yaml
# .github/workflows/android-maestro.yml (in your app repo)
name: Android Maestro E2E
on:
    workflow_dispatch:
    pull_request:
    push:
        branches: [main]
jobs:
    e2e:
        uses: rnw-community/mobile-ci/.github/workflows/android-maestro.yml@<full-commit-sha>
        with:
            targets: >-
                [{"name":"bare","appDir":"apps/mobile","appId":"com.example.app","prebuildCommand":""}]
            flows-dir: apps/mobile/e2e/flows
```
