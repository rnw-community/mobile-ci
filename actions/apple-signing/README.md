# apple-signing

Installs the caller's Apple signing material for the duration of one job:

0. Records a state file **before** creating anything, so a teardown after a
   half-finished install still knows what to remove.
1. Decodes the distribution certificate (`.p12`), the App Store provisioning
   profile and the App Store Connect API key (`.p8`) from base64 into a
   per-`keychain-name` directory `RUNNER_TEMP/<keychain-name>/` with
   `umask 077` / mode `600`.
2. Downloads Apple's WWDR intermediate certificate and verifies it against a
   pinned SHA-256 before trusting it.
3. Asserts the profile's `application-identifier` entitlement equals
   `expected-application-identifier` (`<team>.<bundle-id>`) — a profile for the
   wrong app fails here rather than producing an archive App Store Connect
   rejects.
4. Creates a **throwaway** keychain under `RUNNER_TEMP/<keychain-name>/` with a
   freshly generated random password, imports the certificate and WWDR into it,
   and **prepends** it to the user keychain search list, preserving every entry
   that was already there.

No secret is ever echoed: every value arrives through a step-level `env:`
block, the keychain password never leaves the step, and only identifiers and
paths are printed.

Composite actions cannot declare a `post:` step, so teardown is a paired
`mode: remove` call guarded by `if: always()`. It reads the state file the
install wrote, restores the **original** keychain search list, deletes the
keychain, and removes `RUNNER_TEMP/<keychain-name>/` wholesale — the decoded
`.p12`, `.p8`, profile, plist and WWDR all live there, so a failed install
cannot strand a secret on a self-hosted runner. The state file is written
*first*, before any of those are created, so this holds for an install that
died at the WWDR download, at `security import`, or anywhere else.

The installed `~/Library/MobileDevice/Provisioning Profiles/<uuid>.mobileprovision`
is deleted **only if this install put it there**. A profile with that UUID that
already existed on the runner is left alone at install and at teardown, so
teardown never destroys signing material it did not create.

`remove` warns rather than failing when there is no state directory at all,
and removes the directory wholesale if it exists without a readable state file.

### Concurrency

This action is **not** safe to run concurrently with another install on the
same host, whatever `keychain-name` says. Three things are process- or
host-global and cannot be namespaced away:

- the user keychain search list — job A's teardown restores the list it saw,
  which no longer describes job B's;
- `~/Library/MobileDevice/Provisioning Profiles/` — Xcode only reads profiles
  from that one directory, so two jobs using the same profile share the file;
- the App Store Connect key is now under `RUNNER_TEMP/<keychain-name>/`, so
  that one *is* isolated.

Install fails closed if `RUNNER_TEMP/<keychain-name>/` already exists, which
catches the common case of a leaked previous install on the same runner.
Serialise signing jobs on a host (a concurrency group, or one publish job)
rather than relying on distinct `keychain-name` values.

## Inputs

| Name                              | Required | Default                        | Description                                                        |
| --------------------------------- | -------- | ------------------------------ | -------------------------------------------------------------------- |
| `mode`                            | no       | `install`                      | `install` or `remove`.                                               |
| `certificate-base64`              | no       | `''`                           | Base64 `.p12`. Required for `install`.                               |
| `certificate-password`            | no       | `''`                           | Password protecting the `.p12`. Required for `install`.              |
| `profile-base64`                  | no       | `''`                           | Base64 `.mobileprovision`. Required for `install`.                   |
| `asc-key-base64`                  | no       | `''`                           | Base64 App Store Connect `.p8`. Required for `install`.              |
| `asc-key-id`                      | no       | `''`                           | ASC key ID; names the written `AuthKey_<id>.p8`. Required for `install`. |
| `expected-application-identifier` | no       | `''`                           | `<team>.<bundle-id>` the profile must declare. Required for `install`. |
| `keychain-name`                   | no       | `mobile-ci-signing`            | Base name of the throwaway keychain and of the state file.           |
| `wwdr-url`                        | no       | Apple's `AppleWWDRCAG3.cer`    | WWDR intermediate certificate URL.                                   |
| `wwdr-sha256`                     | no       | `dcf2…601f`                    | Expected SHA-256 of that certificate.                                |
| `keychain-timeout-seconds`        | no       | `21600`                        | Auto-lock timeout for the throwaway keychain.                        |

Every secret-bearing input is declared optional so the same action can be
called in `remove` mode with no secrets at all; `install` validates each one
and fails closed when it is missing or decodes to an empty file.

## Outputs

| Name            | Description                                            |
| --------------- | -------------------------------------------------------- |
| `profile-uuid`  | UUID of the installed provisioning profile.               |
| `keychain-path` | Path of the throwaway keychain.                           |
| `asc-key-path`  | Path of the written `AuthKey_<id>.p8`.                    |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/apple-signing@v1
  id: signing
  with:
      certificate-base64: ${{ secrets.APPLE_DISTRIBUTION_CERTIFICATE_BASE64 }}
      certificate-password: ${{ secrets.APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD }}
      profile-base64: ${{ secrets.APP_STORE_PROVISIONING_PROFILE_BASE64 }}
      asc-key-base64: ${{ secrets.ASC_PRIVATE_KEY_BASE64 }}
      asc-key-id: ${{ secrets.ASC_KEY_ID }}
      expected-application-identifier: 3R8589YV24.com.example.app

# ... archive and upload ...

- uses: rnw-community/mobile-ci/actions/apple-signing@v1
  if: always()
  with:
      mode: remove
```
