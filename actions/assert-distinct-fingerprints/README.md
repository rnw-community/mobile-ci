# assert-distinct-fingerprints

Fails when two targets of one platform with **different `appId`** resolve to the
**same native key**. `expo-native-key`'s identity is platform, flavor,
toolchain, build-action hash and `fingerprint.config.js` hash; the target name
is not in it. Two white-label targets whose native config differs only in
something the fingerprint does not see (brand assets, a per-target config file)
therefore share one base address, and the repack ships the wrong base.

Targets with the **same** `appId` sharing a key are a legitimate dedupe and pass.
The error names both targets, the key, and the sources they share (fingerprint
hash, fingerprint config hash, `appDir`). The fix is `extraSources` in
`fingerprint.config.js` - see
[docs/repack.md](../../docs/repack.md#targets-that-differ-only-in-brand-assets-or-per-target-config).

A composite action cannot loop over a dynamic target list, so this action takes
keys already computed. `expo-base-plan.yml` runs it in its collect job over the
plan records; release pipelines that never run `expo-base-plan.yml` call the
[`assert-distinct-fingerprints.yml`](../../docs/workflows/assert-distinct-fingerprints.md)
reusable workflow, which computes a key per target with `expo-native-key` before
any build starts and then runs this action. Both share
`scripts/assert-distinct-native-keys.sh`.

## Inputs

| Name       | Required | Default | Description                                                                                                  |
| ---------- | -------- | ------- | ------------------------------------------------------------------------------------------------------------ |
| `platform` | yes      | -       | `ios` or `android`.                                                                                          |
| `plans`    | yes      | -       | JSON array of `{name, appId, nativeKey, appDir?, fingerprint?, configHash?}`, one per target.                 |
| `require-app-id` | no | `true` | `true` requires an `appId` on every target. `false` lets targets that all omit `appId` (the `seed-native-cache.yml` target shape) skip the comparison with a notice; a mix of targets with and without `appId` still fails. `expo-base-plan.yml` passes `false`. |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/assert-distinct-fingerprints@v4.0.0 # v4.0.0
  with:
      platform: ios
      plans: >-
          [{"name":"brand-a","appId":"com.a","nativeKey":"k1"},
           {"name":"brand-b","appId":"com.b","nativeKey":"k1"}]
```
