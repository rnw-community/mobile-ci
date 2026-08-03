# native-fingerprint

Hashes the native surface of a React Native / Expo app with the standalone
[`@expo/fingerprint`](https://www.npmjs.com/package/@expo/fingerprint) CLI —
tokenless, no EAS account, no `EXPO_TOKEN`, no `eas-cli` install. The
fingerprint tracks native inputs only (`package.json`, native folders,
autolinking config); JS-only application code does not shift it. Consumers use
the output `hash` as one segment of a native-app-cache key (see
`native-app-cache`) — a cache hit means "the native shell is safe to reuse",
not "the embedded JS bundle is current for this commit".

## Inputs

| Name                   | Required | Default   | Description                                    |
| ----------------------- | -------- | --------- | ----------------------------------------------- |
| `platform`              | yes      | —         | `ios` or `android`.                              |
| `working-directory`     | no       | `.`       | App directory to fingerprint.                    |
| `fingerprint-version`   | no       | `0.20.6`  | Pinned `@expo/fingerprint` npm version.          |

## Outputs

| Name   | Description                     |
| ------ | -------------------------------- |
| `hash` | The computed native fingerprint. |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/native-fingerprint@v1
  id: fingerprint
  with:
      platform: ios
      working-directory: apps/bare

- run: echo "${{ steps.fingerprint.outputs.hash }}"
```
