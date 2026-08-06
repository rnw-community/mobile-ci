# mobile-ci: SOTA consolidation — design

Date: 2026-08-06
Status: approved for phase 1 execution (docs + backward-safe action/workflow changes); phase 2 (consumer migrations) pending owner review.

## Problem

mobile-ci is pre-v1. Two consumers track adoption (suuudokuuu#247, budgie#627) and two draft
adoption PRs (suuudokuuu#253, budgie#628) are blocked on gaps in this repo. Docs reference
specific consumer projects throughout and lack the repo-health/docs conventions of best-in-class
actions. Submit/publish and dev-release pipelines still live hand-rolled in consumers.

## Inputs (research summary)

1. Both adoption PRs hit the identical blocker: `run-maestro-ios` / `run-maestro-android`
   discover flows recursively (`*.yaml`/`*.yml`), sweeping up subflows/fixtures. The Redroid
   runner already has `flows-name-pattern` (default `*.flow.yaml`, top-level only).
2. budgie#628 open questions: (a) no fresh-JS repack on native-cache hit — a JS-only PR can pass
   E2E against stale JS; (b) one `runner-labels` for both build and test jobs, but budgie runs
   separate `macos-builder`/`macos-maestro` pools; (c) no env passthrough to the build job —
   worked around via `prebuildCommand` string hacks.
3. suuudokuuu#249 (iOS shard flake): consumer-side flow hygiene, but per-flow retry and a
   pre-run priming flow (both present in suuudokuuu's hand-rolled harness, lost in PR #253's
   migration) mitigate it. Flow-timing summaries also lost in migration.
4. Missing capability with proven consumer implementations: publish (EAS local build →
   `eas submit` App Store / Google Play → optional fastlane metadata; Play-policy lint gate,
   64-bit ABI verification) and dev builds published to pruned GitHub Releases.
5. SOTA research (docker/build-push-action, expo-github-action, codeql-action,
   android-emulator-runner, maestro-cloud, softprops/action-gh-release): our per-action README
   layout matches the best monorepo analog (expo-github-action). Gaps: no RELEASE.md, no
   SECURITY.md, no CODEOWNERS, no issue templates, no badges, no zizmor audit, no workflow-level
   input docs, no CHANGELOG stance. Marketplace fact: only a root `action.yml` can be listed;
   subdirectory actions cannot — codeql-action/expo-github-action simply document that stance.
   No top repo keeps an `examples/` folder; examples live in README/docs.

## Design decisions

Pre-v1: breaking changes allowed; consistency wins over compatibility.

### D1. Unified flow discovery
Add `flows-name-pattern` (default `*.flow.yaml`) to `run-maestro-ios` and `run-maestro-android`,
matching the Redroid runner exactly: top-level of `flows-dir` only, non-recursive. Expose as an
input on `ios-maestro.yml` / `android-maestro.yml` and thread through. Subflows/fixtures in
subdirectories are the documented convention.

### D2. Split runner pools
`ios-maestro.yml` / `android-maestro.yml` gain `build-runner-labels` and `test-runner-labels`
(default `''` → fall back to `runner-labels`). `runner-labels` stays as the simple path.

### D3. Build env passthrough
Both pipelines gain `build-env` (newline-separated `KEY=VALUE`), appended to `$GITHUB_ENV` at
the start of the build job via a fail-closed parser (reject names not matching
`[A-Za-z_][A-Za-z0-9_]*`, values passed through env not string interpolation). Replaces
budgie's prebuildCommand hack.

### D4. Repack-on-hit (fresh JS into cached native shell)
New composite action `repack-app` (platform ios/android): runs `npx @expo/repack-app`
(version input, default `0.7.2`) to inject a freshly exported JS bundle into the cached
`.app`/`.apk`, then validates (expected app id via `PlugIns`-free Info.plist / `aapt2 dump
packagename`, jsbundle presence). Integrated into ios-maestro/android-maestro build jobs behind
`repack-on-hit` (default `false`): on native-cache hit, repack instead of skipping the build; on
repack failure, fall back to full native build (never fail the job on repack alone).
This closes budgie's stale-JS correctness gap. seed-native-cache does not repack (build-only).

### D5. Runner ergonomics (all three Maestro runners)
- Flow-timing summary table to `$GITHUB_STEP_SUMMARY` (per-flow name, duration, status).
- `pre-run-flow` (optional path): a priming flow executed once before the shard, not counted.
- `flow-retries` (default `0`): per-flow retry budget for transient driver failures.

### D6. Publish pipelines (new reusable workflows)
- `native-publish.yml` (`workflow_call`): generalizes suuudokuuu's publish flow, degrades to
  budgie's iOS-only shape via toggles.
  - Inputs: `enable-ios`/`enable-android`, per-platform runner labels, `app-dir`, node/install/
    corepack/build-command (same conventions as existing pipelines), `eas-cli-version`
    (default `20.5.1`), `build-profile`/`submit-profile` (default `production`),
    `pre-submit-command` / `post-submit-command` per platform (fastlane hooks stay
    consumer-owned strings), `android-lint-gate` (default `true`, hosted-runner
    `lintVitalRelease` + restricted-permissions manifest check), `required-android-abi`
    (default `arm64-v8a`, verified in the built artifact).
  - Secrets (`workflow_call` secrets, optional per platform): `EXPO_TOKEN`,
    `ASC_API_KEY` (materialized to a temp file, removed in `always()`),
    `GOOGLE_SERVICE_ACCOUNT_JSON` (same handling).
- `native-dev-release.yml` (`workflow_call`): EAS local dev build per enabled platform →
  publish artifacts to a GitHub Release (`tag-prefix` input, deterministic
  `run_number.run_attempt` build number) → prune to `keep-releases` (default `5`).
- Both added to self-test dry-lint coverage.

### D7. Docs: generic + SOTA
- Root README: badge row (self-test CI, license), hero + zero-EAS/zero-secrets-custody framing
  stated explicitly, quick start near top, action catalog, workflow catalog linking to per-
  workflow reference docs, Redroid-vs-AVD, scope, versioning note. ALL consumer-project
  mentions removed; a final section "Used in the wild" links consumer repos/workflows
  (suuudokuuu, budgie, rnw-community) as usage examples.
- All per-action READMEs genericized: placeholders `com.example.app`, `apps/mobile`,
  `MyApp.xcworkspace` / `MyApp` scheme, `apps/mobile/e2e/flows`.
- New `docs/`:
  - `docs/workflows/<name>.md` — full input/secret tables + example call for each of the six
    reusable workflows (closes the "20+ undocumented workflow inputs" gap).
  - `docs/self-hosted-runners.md` — Redroid host provisioning (binder_linux, prewarm manifest
    `{image,dataDir}` format and how to produce it), macOS pool topology guidance, self-test
    repo vars (`MOBILE_CI_SELFTEST_XCODE_*`).
- Repo health: `SECURITY.md`, `CODEOWNERS`, `.github/ISSUE_TEMPLATE/{bug.yml,feature.yml,
  config.yml}`, `RELEASE.md` (checklist: exact tag + moving `v1` major tag + GitHub Release
  with generated notes; no CHANGELOG.md by explicit choice), zizmor job added to self-test CI.
- Marketplace stance documented in CONTRIBUTING: monorepo of path-referenced composite actions,
  not Marketplace-listed by design (subdirectory actions cannot be listed).

### Out of scope (tracked for phase 2, consumer repos)
- Updating suuudokuuu#253 / budgie#628 to consume the new inputs and un-draft.
- Migrating consumers' `native-publish.yml`/`native-dev-build.yml` onto D6.
- suuudokuuu#249 flow hygiene (extendedWaitUntil, deep-link entry states) — consumer-side.
- Weighted/explicit shard lists (budgie's hand-balanced shards): revisit only if modulo
  sharding proves unbalanced after adoption; `flow-retries` + timing summaries land first.

## Testing
`actionlint` + `shellcheck` via existing self-test lint jobs (including local-ref dry-lint for
all reusable workflows); zizmor once added. Real-device validation happens via consumer draft
PRs re-pointed at this branch's SHA before v1 is tagged.
