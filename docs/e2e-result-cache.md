# Content-addressed E2E pass records

A store description, screenshot output, documentation edit or unrelated workflow
has no reason to rebuild or retest a byte-identical app. Opt-in
`e2e-result-cache: true` moves that decision from a list of exempt source paths
to the actual production app and test contract. Both Maestro workflows support
it; existing callers retain today's behavior by default.

## Decision and identity

The Linux planner installs dependencies and runs the existing workspace build,
prebuild and native-key computation. Before fetching a base binary it exports
production JavaScript/assets with the **installed** Expo CLI:

```sh
NODE_ENV=production npx --no-install expo export --platform ios --output-dir <fresh-directory> --clear
NODE_ENV=production npx --no-install expo config --type public --json
```

Android uses `--platform android`. The build environment/secrets are already
applied; `repack-env` is applied over them just as in the real repack. Neither
command installs an unrelated latest CLI. A fresh export must contain a nonempty
platform production bundle. The entire output is hashed, including all chunks,
Hermes bytecode when configured, assets and metadata. The resolved public config
is separately included: changes to values the native fingerprint deliberately
skips can still change what the app reads at runtime.

The key is SHA-256 of a recursively sorted JSON object containing:

- Schema version, consumer repository and platform.
- Existing native key: fingerprint, fingerprint-config contract, native build
  action identity, build-secret digest, toolchain, scheme/workspace and ABI.
- Sorted export tree paths, file bytes, file/directory modes and empty directories;
  plus resolved public app config. Paths are relative to the fresh export root;
  timestamps and absolute export-directory names are not hashed.
- Test dependency paths and content trees: resolved target's `flowsDir` by
  default, explicit Maestro config, pre-run/recovery flows and shard manifests,
  plus `e2e-cache-extra-paths`. Symlinks are followed and their content hashed;
  cycles, special files, missing paths and unmatched patterns disable reuse.
- All workflow inputs as canonical JSON and the resolved target. This includes
  test selection, hooks, retries, shard count, Maestro version, build/repack
  settings, driver, device profile, Android API/ABI/image settings, Xcode and
  simulator settings. Changing inputs conservatively misses even if irrelevant.
- The executing action ref, resolved Maestro/planner workflow refs and SHAs
  from GitHub's current run-attempt API, and the content of mobile-ci's actions
  and reusable workflows. Updating mobile-ci invalidates evidence from the old implementation.
- Maestro secret digest (parsed/masked by `apply-secret-env` without exporting
  it into the app build) and the optional state-command stdout digest. Values,
  bundles and resolved configs never enter the pass record or job outputs.

Source revision, PR number, caller workflow file bytes and an unrelated file's
path are deliberately absent. A CI-only edit which changes no passed lane input,
app output or test dependency reuses a pass. A changed hook command, device or
Maestro version does not. Native-only changes change the native key; JS, lazy
chunks, bundled images and config changes change the export/config identity.

The complete output hash is more reliable than a source-file/lockfile digest:
Metro resolves workspace dependencies, package exports, Babel transforms,
platform extensions, static assets and Expo Router chunks. A source allowlist
cannot reliably model all of those. Nondeterministic output produces extra
misses, never false hits; the action does not strip source URLs, runtime config
or arbitrary metadata in pursuit of a stable key.

The existing native-key correctness boundary still applies: ignored paths must
not alter native behavior. If a warm-up intentionally force-replaces a base
under the **same** native key, delete that key's E2E pass caches or advance the
state-command's version before trusting it again. The base tag is otherwise an
immutable input; overwriting it cannot preserve old test evidence.

## Exporter and test dependency contract

`expo export` is suitable for standard Expo/Metro production bundling. Check
export repeatability and invalidation on the actual app before enabling reuse.
If native build/repack uses different entrypoints, Babel/Metro modes, environment
values, custom asset processing, dynamic code generation, or nonstandard RN
bundling, provide `e2e-cache-export-command` to reproduce that production
payload. It runs in `app-dir` with `$E2E_CACHE_EXPORT_DIR` naming a fresh absolute
directory. Write a nonempty `bundle`, valid `config.json` (resolved runtime
configuration; `{}` only if none) and **all** shipped assets/chunks there. Every
output byte is hashed. A bare React Native project can invoke its installed
Metro/RN CLI in this command; the exporter must use the native lane's entry,
platform, production flags and asset settings. Export failures or missing files
fall back to running; the cache does not replace the native planner's Expo
fingerprint requirements.

Test dependency declarations are the equivalent of build inputs, not a list of
app paths declared safe to ignore. `e2e-cache-test-paths` can replace the default
flow tree when E2E and capture-only flows share a parent. Automatic config,
pre-run/recovery and shard paths are still included. Extra paths must cover
fixtures, script imports, `runScript`/`runFlow` dependencies outside those trees,
shared test packages, generated inputs and hook dependencies. Patterns use Node's
file glob syntax; every pattern must match. Changing the selected path set also
changes the key. New files matching a glob are automatically included.

Avoid hashing an entire test package if it also holds store screenshots: declare
the actual E2E trees/files and move shared dependencies into clearly owned
directories over time. Under-declaring dependencies can produce stale evidence;
over-declaring only costs runs. If a flow starts consuming another directory,
add that dependency in the same PR. Do not omit a runtime input just because it
looks like documentation or a screenshot: imported content is app/test input.

A verdict can only be reused for a deterministic test contract. Remote backend
data, wall clock and mutable simulator/cloud images are additional inputs.
Freeze them or include a version through `e2e-cache-state-command`; do not enable
reuse against an unversioned live service. For date-relative fixtures,
`date -u +%F` limits reuse to a UTC day (pin the fixture/device timezone too).
Version the fleet image/runtime whenever it changes independently of the passed
device/toolchain inputs. A command returning nothing or failing disables reuse.

## Pass record store and trust

Pass records live in the **consumer's GitHub Actions cache**, under exact key
`mobile-ci-e2e-v1-<sha256>`, at `.ci-cache/e2e-result/<sha256>/pass.json`.
The record contains only schema, repository, key, `passed` verdict and the
producer's GitHub run-attempt URL. `/restore` must report an exact `cache-hit`,
and the JSON must validate before any target can be removed. Cache entries are
immutable. Races saving the same pass are harmless.

Actions cache is chosen over GHCR and check/status lookup because it supplies
branch isolation and exact immutable lookup without a registry tool/bootstrap,
extra token scopes, run pagination or commit association. It already works with
pnpm, yarn and npm consumers. Eviction, disabled cache, read-only credentials,
cache-service errors or corrupt records simply cause a real run.

GitHub scopes a PR-created cache to its merge ref; sibling PRs and the default
branch cannot consume it. Default-branch records are readable by PRs. Keep
normal `pull_request` execution; never introduce a privileged
`pull_request_target` writer for untrusted code. Do not save secrets in records
or enable a proxy that changes these trust guarantees. Like other Actions
caches, records are evidence from workflows allowed to write in the same branch
scope, not cryptographic attestations against a compromised runner/repository.

Sources: [GitHub cache scope and matching](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching),
[Expo production export](https://docs.expo.dev/more/expo-cli/).

GHCR would allow cross-PR reuse without `main` seeding, but writable same-repo
PR tokens could then publish evidence consumed by other PRs. Solving that safely
requires a separate trusted writer/attestation protocol. Commit checks have no
native content-key index and require API pagination and extra write scopes.
Neither is needed for this opt-in.

## Workflow behavior and failure handling

1. With caching enabled, package/path-based Turbo detection is bypassed so it
   cannot silently override the content decision. The force label still works.
2. Each target independently computes and looks up a key before base fetch.
   Validated hits skip base download, repack, native build and every Maestro
   shard. Mixed hit/miss matrices run only the misses.
3. Native strategy, force-label runs, manual `workflow_dispatch` and quarantined
   targets bypass caching. A forced real run must really execute; a tolerated
   test failure can never become a cached pass.
4. After **every** active test shard succeeds, a small control-runner matrix saves
   records for eligible misses. A failed/cancelled/timed-out shard prevents all
   new publication in that call, even if some siblings passed. Cache save failures
   do not turn a real passing suite into a failing suite.
5. The existing final result job reports `result=passed` on complete cached
   evidence and includes producer links. Required checks stay successful. Empty
   matrices or skipped tests without validated records still fail. A wholly
   Turbo-unaffected run with caching disabled remains `skipped`, as before.

An E2E identity, workflow-ref lookup, secret-digest, export or record error is an optimization miss:
run the existing full lane. Existing failures in dependency install, prebuild,
native fingerprint computation, plan collection or app verification still fail
normally; the cache does not hide a broken build. No negative/failure records
are published. Delete `mobile-ci-e2e-v1-*` entries to invalidate stored evidence,
use the force label/manual dispatch for a real run, or turn the input off.
Cached hits intentionally produce no new app or Maestro artifacts: downstream
capture jobs requiring those artifacts must use a non-cached/manual lane.

## Cost and rollout

The planner already installs, builds workspace dependencies, prebuilds and
fingerprints. Incremental cost is one production export, one public-config
resolution, hashing and a tiny cache restore. On a miss the existing repack
bundles again; exported output is deliberately not transplanted into an
unverified repack format. Expect **1–5 additional Linux minutes per target**
for a medium Expo monorepo; large bundles may cost more. This is an estimate,
not a fleet measurement. The identity step emits measured export/hash seconds
on every run, so rollout can establish p50/p95. Plan with 4 vCPU/8 GiB when Metro
exceeds the small pool's memory. A warm hit avoids the Mac/Gradle slot, repack,
emulator/simulator startup and all shards (Budgie's reported 40+ minute lane).

1. Pin the new release/SHA after review. New self-references name upcoming
   `v4.5.0`; this PR does not create a tag. To fleet-test a prerelease SHA,
   follow RELEASE.md's self-reference SHA-pin procedure in a separate validation
   change. Do not call the branch with unresolved upcoming references.
2. Define the complete test/export/device/state contract; enable on the default
   branch's **actual E2E run**, not `seed-native-cache.yml`. That warm-up builds
   bases and runs no Maestro, so it cannot publish pass records. Use identical
   inputs on default-branch and PR calls. Manual dispatch deliberately runs but
   does not seed the content cache; a successful `push` run seeds it.
3. Verify a production baseline, then a metadata-only change that reuses it.
   Check the producer links, empty build/test matrices and absence of app
   artifacts. Verify JS/assets, native dependency, fixture/hook, Maestro/input,
   device profile and state-version changes miss. Test failed/cancelled shards,
   malformed records and unavailable cache. Run one fleet lane at a time.
4. Remove the consumer path exemption classifier. Until a shared default-branch
   record exists, the first PR runs normally and its later identical pushes can
   reuse that PR's own record. Cross-PR savings require the baseline push lane.

### Budgie

The inspected `pr.yml` pins v4.4.1 and has a JS path-exemption classifier plus a
Turbo gate. Keep the native variant's `fingerprint-env`, `build-env` and
`repack-env` byte-identical (`APP_VARIANT=e2e`, AI/logging disabled). The existing
GHCR `e2e-base` warm-up remains unchanged.

The [exact proposed PR workflow patch](examples/budgie-e2e-result-cache.patch)
removes the classifier and its dependencies, pins the upcoming version, enables
the cache and declares E2E inputs separately from screenshot/media fixtures.
It also includes the UTC date state command because
`prepare-date-sensitive-fixtures.js` and the fixture installer read the clock.
This is a proposed consumer change only; no consumer repository is modified.
Pair it with a push-triggered default-branch E2E call passing the same inputs.
Budgie's native warm-up alone is insufficient to seed successful test evidence.

### suuudokuuu

`pr.yml` calls local `mobile-e2e.yml`, which calls both platform workflows at
v4.4.2. Enable the cache on **both** calls in `mobile-e2e.yml`; pass each lane's
fixture/script dependencies and appropriate state version. Remove the `changes`
mobile path classifier only from the mobile E2E dependency; web checks may keep
their own independent policy. The workflow already has a main push trigger:
remove its broad path filter for content-based decisions on every push, or keep
it only as a conservative prefilter after proving the dependency contract.
Do not hash `.github/workflows` as an extra tree: relevant passed input changes
already invalidate the record, unrelated store workflow changes should not.
The manual Android capture smoke consumes the built app artifact, so keep that
manual lane uncached (the built-in dispatch bypass already does so).

## Companion: store-only automation

Metadata upload should be a Linux job calling [Fastlane `deliver`](https://docs.fastlane.tools/actions/deliver/) with
`skip_binary_upload: true`, `skip_screenshots: true` for copy-only work, and no
build/submit-build step. Upload **existing** screenshot images in a separate job
with binary upload disabled; capture/regenerate screenshots is a different
workflow that intentionally needs an app and simulator. On Android use [supply](https://docs.fastlane.tools/actions/supply/)'s
`skip_upload_apk: true` and `skip_upload_aab: true`, with explicit metadata/image
selection. Pin tools, use store credentials only on a trusted push/manual job,
and keep required review on publication environments. These are documentation
patterns, not new upload jobs in this PR.

PR copy checks should be cheap Linux jobs: validate supported locale folders,
required localized fields, title/subtitle/promotional/description length limits,
UTF-8, forbidden placeholders and screenshot image dimensions when present.
Validate against current store requirements in the consumer's metadata tooling;
none of these checks needs Xcode, Gradle or Maestro. A change to screenshot
capture code that is genuinely shared with E2E should still invalidate E2E.
