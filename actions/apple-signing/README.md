# apple-signing

Installs the caller's Apple signing material for the duration of one job:

1. Decodes the distribution certificate (`.p12`), the App Store provisioning
   profile and the App Store Connect API key (`.p8`) from base64 into
   `RUNNER_TEMP` with `umask 077` / mode `600`.
2. Downloads Apple's WWDR intermediate certificate and verifies it against a
   pinned SHA-256 before trusting it.
3. Asserts the profile's `application-identifier` entitlement equals
   `expected-application-identifier` (`<team>.<bundle-id>`) — a profile for the
   wrong app fails here rather than producing an archive App Store Connect
   rejects.
4. Creates a **throwaway** keychain under `RUNNER_TEMP` with a freshly
   generated random password, imports the certificate and WWDR into it, and
   prepends it to the user keychain search list.

No secret is ever echoed: every value arrives through a step-level `env:`
block, the keychain password never leaves the step, and only identifiers and
paths are printed.

Composite actions cannot declare a `post:` step, so teardown is a paired
`mode: remove` call guarded by `if: always()`. It reads the state file the
install wrote, restores the **original** keychain search list, deletes the
keychain, the installed `.mobileprovision`, the ASC key and every scratch file.
It exits with a warning (not a failure) when there is no state file, because
that means the install never got far enough to write anything.

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

Two jobs on the same runner keep separate state as long as they pass different
`keychain-name` values.

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
