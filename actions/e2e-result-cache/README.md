# e2e-result-cache

An exact successful verdict for a native surface, production JavaScript/assets,
resolved app config, test dependency trees, and device/lane configuration.
Composite action; Node 22.17+ is required for file-glob expansion. Install app
dependencies and build workspace dependencies before lookup. Prefer the
[`ios-maestro`](../../docs/workflows/ios-maestro.md) and
[`android-maestro`](../../docs/workflows/android-maestro.md) integrations.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `mode` | `lookup` | `lookup` or `publish`. Only publish after all actual, non-quarantined shards pass. |
| `platform` | required | `ios` or `android`. |
| `app-dir` | `.` | Installed project directory. |
| `native-key` | empty | Exact variant's `expo-native-key` identity. Required for lookup. |
| `workflow-refs` | `[]` | Resolved reusable workflow refs/SHAs from the current run-attempt API; shared planner supplies these automatically. |
| `lane-inputs` | `{}` | JSON of all workflow inputs, including the device and tool versions. |
| `target` | `{}` | JSON of the resolved target. |
| `test-paths` | empty | Newline-separated test dependencies relative to repo root; literal files/directories or globs. Every pattern must match. |
| `extra-paths` | empty | Additional fixtures, scripts and dependency trees. Same syntax as `test-paths`. |
| `state-command` | empty | App-directory command whose nonempty stdout versions mutable state, e.g. `date -u +%F`; only its digest enters the key. Errors prevent reuse. |
| `export-command` | empty | Custom exporter, run from app-dir. Write nonempty `bundle`, valid `config.json` and all assets under `$E2E_CACHE_EXPORT_DIR`. Empty uses the installed Expo CLI. |
| `repack-env` | empty | Same `KEY=VALUE` environment as the production repack; applied over the job's build environment. |
| `secrets-digest` | empty | Maestro environment digest from `apply-secret-env` with `export: 'false'`. Raw secrets are rejected. |
| `key` | empty | SHA-256 from an earlier lookup; required for publish. |

## Outputs

| Output | Description |
| --- | --- |
| `key` | SHA-256 identity, empty on computation failure. |
| `hit` | `true` only after exact restore **and** pass-record validation; otherwise `false`. |
| `run-url` | Successful producer run attempt on a validated hit. |

```yaml
- name: Look for a previous pass
  id: verdict
  uses: rnw-community/mobile-ci/actions/e2e-result-cache@v4.5.0 # v4.5.0
  with:
    platform: ios
    app-dir: apps/mobile
    native-key: ${{ steps.native.outputs.key }}
    lane-inputs: '{"device":"iPhone 17 Pro","runtime":"iOS 26.4","maestro":"2.6.1"}'
    target: '{"name":"e2e","appId":"com.example.app"}'
    test-paths: tests/mobile
```

The action uses `actions/cache/restore` and `/save` with the exact
`mobile-ci-e2e-v1-<sha256>` key and the same relative record path in both jobs.
No restore prefixes or artifact-name heuristics can produce a hit. A restored
file is validated as JSON data, never executed. See the
[design and rollout guide](../../docs/e2e-result-cache.md) for scope, trust,
key composition, exporter correctness and fixture dependency obligations.
