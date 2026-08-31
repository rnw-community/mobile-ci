# load-consumer-config

Reads a consumer-owned JSON configuration file out of the checked-out
repository, validates it, and emits it as one compact JSON object a reusable
workflow can resolve its inputs against — so a caller can keep its
app-shaped configuration in a reviewable, editor-completable file instead of
passing giant JSON-in-YAML string blobs through `with:`.

The action does **not** know anything about a particular workflow's inputs:
the caller passes the allowlist of key names it is willing to load, and the
action fails closed on anything outside it. Rejecting unknown keys is the
point — a typo in a config file would otherwise be silently ignored and the
run would use defaults nobody asked for.

Fail-closed conditions, each naming the offending path/key:

- `config-path` is empty, absolute, or contains a `..` segment.
- The file does not exist in the checkout, or is a symlink.
- The path resolves outside `$GITHUB_WORKSPACE` (directory components are
  canonicalized with `pwd -P`, so a symlinked parent directory cannot smuggle
  the read out of the checkout either).
- The path is not a regular, readable file.
- The file is not valid JSON.
- The top level is not a JSON object.
- The object has a top-level key that is not in `allowed-keys`.
- `allowed-keys` is not a JSON array of non-empty strings.

Requires `jq` on the runner. The file is read only — the action never writes
to the repository and never resolves values against defaults; interpreting
the object (types, precedence, defaults) is the calling workflow's job.

## Inputs

| Name           | Required | Default | Description                                                                              |
| --------------- | -------- | ------- | ----------------------------------------------------------------------------------------- |
| `config-path`   | yes      | —       | Repository-relative path to the consumer's JSON config file.                               |
| `allowed-keys`  | yes      | —       | JSON array of the top-level key names the config file may contain; anything else fails closed. |

## Outputs

| Name   | Description                                                            |
| ------ | ----------------------------------------------------------------------- |
| `json` | The validated config object, compact single-line JSON (e.g. `{"a":1}`). |

## Example

```yaml
- name: Check out just the config file
  uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6.1.0
  with:
      persist-credentials: false
      sparse-checkout: .github/store-screenshots.config.json
      sparse-checkout-cone-mode: false

- name: load-consumer-config
  id: load-config
  uses: rnw-community/mobile-ci/actions/load-consumer-config@v1
  with:
      config-path: .github/store-screenshots.config.json
      allowed-keys: '["capture-mode","screenshots-dir","settle-seconds"]'

- name: Use a value
  shell: bash
  env:
      CAPTURE_MODE: ${{ fromJSON(steps.load-config.outputs.json)['capture-mode'] }}
  run: echo "$CAPTURE_MODE"
```
