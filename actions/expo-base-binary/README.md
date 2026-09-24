# expo-base-binary

Fetches or publishes the base binary a [repack](../expo-repack) starts from,
addressed by the native key from [`expo-native-key`](../expo-native-key) alone.

Two backends, one contract:

- **`ghcr`** (default) stores the base as an immutable OCI artifact at
  `ghcr.io/<owner>/<repo>/e2e-base:<platform>-<flavor>-<key>`, pushed and pulled
  with `oras`. No retention clock, no artifacts-API pagination, one tag per key.
  Needs `packages: write` on the publishing job and `packages: read` on the
  fetching one.
- **`artifact`** stores it as a workflow artifact named
  `e2e-base-<platform>-<flavor>-<key>`, and accepts a base **only** from a run
  whose `head_branch` is the default branch and whose head repository is this
  repository — so a pull request can never repack onto a base another pull
  request built. Needs `actions: read`. Use it where publishing packages is not
  an option; workflow artifacts expire, so a key can go cold and cost a native
  build again.

Either way a published base is **immutable**: `publish` never overwrites an
address that already holds one unless `force: true` is set, because a key
already in use must keep meaning the same binary.

Publishing is **idempotent**. Two default-branch runs that build the same native
key — the warm-up and the e2e run on the same push — both reach `publish`, and
the second finds the address taken. That is the outcome both wanted, so the
second run succeeds with a notice and pushes nothing — on `ghcr` the notice
names the revision and manifest digest that published the base, on `artifact`
it names the default-branch artifact. On `ghcr` the existing manifest is checked first: its
`artifactType` and its `platform`, `flavor` and `native-key` annotations must
be the ones this publish would write. Anything else at the address fails the
step, because it is not this key's base and is still never overwritten without
`force`. On `artifact` the name is the key, so an artifact already under it —
from a default-branch run of this repository, exactly the ones a fetch accepts —
is this key's base. The binaries themselves are not compared: two
native builds are not byte-identical, and the key is what says they are
interchangeable.

`oras` is not assumed to be on the runner. An `oras` of exactly `oras-version`
already on `PATH` is reused; otherwise the release asset for the runner's OS and
architecture is downloaded and checked against `oras-checksums` before it is
used. A runner whose OS/arch has no entry there fails with that named, rather
than running an unverified binary.

A fetch that finds nothing reports `found=false` — that is the signal to build
natively and publish. A fetch that *cannot tell* (registry error, artifacts API
failure) fails the job: an unreadable store is not an absent base.

## Inputs

| Name                     | Required | Default                                       | Description                                                                 |
| ------------------------ | -------- | --------------------------------------------- | ---------------------------------------------------------------------------- |
| `mode`                   | yes      | —                                             | `fetch` or `publish`.                                                        |
| `platform`               | yes      | —                                             | `ios` or `android`.                                                          |
| `key`                    | yes      | —                                             | Native key from `expo-native-key`. Empty fails closed.                       |
| `flavor`                 | no       | `e2e`                                         | Flavor segment of the base's address.                                        |
| `backend`                | no       | `ghcr`                                        | `ghcr` or `artifact`.                                                        |
| `path`                   | yes      | —                                             | Publish: the file to store. Fetch: the directory it is pulled into.          |
| `registry`               | no       | `ghcr.io`                                     | OCI registry host.                                                           |
| `repository`             | no       | `${{ github.repository }}`                    | `<owner>/<repo>` the base is stored under; lowercased.                       |
| `image-name`             | no       | `e2e-base`                                    | Repository path after `<registry>/<repository>/`.                            |
| `token`                  | no       | `${{ github.token }}`                         | Registry login / artifacts API token.                                        |
| `default-branch`         | no       | `${{ github.event.repository.default_branch }}` | The only branch the `artifact` backend accepts a base from.                |
| `force`                  | no       | `false`                                       | Publish over an address that already holds a base.                           |
| `oras-version`           | no       | `1.3.4`                                       | Pinned oras CLI version.                                                     |
| `oras-checksums`         | no       | linux/darwin amd64+arm64                      | `<os>_<arch>=<sha256>` entries for the pinned release's assets.              |

## Outputs

| Name        | Description                                                        |
| ----------- | ------------------------------------------------------------------- |
| `found`     | `true` when a fetch produced a base binary.                         |
| `path`      | Path of the fetched base binary; empty when none was found.         |
| `source`    | `ghcr`, `artifact`, or `none`.                                      |
| `reference` | The OCI reference or artifact name the base is addressed by.        |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/expo-base-binary@v3.1.0 # v3.1.0
  id: base
  with:
      mode: fetch
      platform: ios
      key: ${{ needs.plan.outputs.key }}
      path: .ci-cache/e2e-base/bare

- if: steps.base.outputs.found != 'true'
  run: echo 'No base for this native key yet; build natively and publish one.'
```
