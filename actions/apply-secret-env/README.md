# apply-secret-env

Turns a secret holding newline-separated `KEY=VALUE` entries into masked job
environment variables. It is the one parser behind every secret env this repo's
workflows take — `build-secrets-env` and `maestro-secrets-env` on the e2e,
warm-up and screenshot workflows, and `EAS_EXTRA_ENV` on `native-publish.yml`,
`native-dev-release.yml` and `store-screenshots.yml`.

What it guarantees:

- **Masked before anything can print it.** Every value is registered with
  `::add-mask::` while the secret is parsed, before it is exported or written to
  an output. A multi-line value is masked line by line, since the runner masks
  per log line. `%` and carriage returns are escaped the way the runner
  unescapes command data, so the string masked is the string printed. An empty
  value is not masked.
- **Fails closed, and never echoes.** A line without `=`, a name that does not
  match `^[A-Za-z_][A-Za-z0-9_]*$`, or a multi-line value whose delimiter never
  closes fails the step, naming only the line number — the line itself may be
  the secret. Nothing is exported until the whole secret has parsed.
- **No value can escape its entry.** Each entry is written to `$GITHUB_ENV` as
  `NAME<<DELIMITER` with a fresh random delimiter, re-drawn if the value happens
  to contain it, so a value can never end its own entry and start another.
- **Only a digest leaves.** The `digest` output is a SHA-256 over every entry's
  name and the SHA-256 of its value. It changes whenever any value does and
  reveals none of them; `expo-base-plan.yml` folds it into the native key so a
  rotated key compiled into a base invalidates that base.

A multi-line value (a PEM key, a JSON credential) is written the way
`$GITHUB_ENV` itself takes one:

```text
TURBO_TOKEN=abc123
GOOGLE_SERVICES_JSON<<EOF
{
  "project_info": { "project_id": "demo" }
}
EOF
```

The delimiter must be letters, digits and underscores. Every non-empty line of
a multi-line value is masked, so a line like `{` would be masked everywhere in
the job log; prefer a base64-encoded single line where you can.

With `allow-multiline: false` a multi-line entry fails the step, and the
`lines` output carries `append-to` followed by every entry as one `KEY=VALUE`
line — that is how `maestro-secrets-env` is merged into `maestro-env`, whose
values become Maestro `-e` arguments. The merged list carries secret values, so
it is only usable inside the same job: GitHub drops a job output that contains a
masked value, and it must never be one.

## Inputs

| Name              | Required | Default      | Description |
| ----------------- | -------- | ------------ | ----------- |
| `env`             | no       | `''`         | Newline-separated `KEY=VALUE` entries, normally `secrets.<name>`; `KEY<<DELIMITER` … `DELIMITER` for a multi-line value. Empty is a no-op. |
| `label`           | no       | `secret-env` | Name the error messages give the secret. |
| `export`          | no       | `'true'`     | Append every entry to `$GITHUB_ENV` for the rest of the job. |
| `allow-multiline` | no       | `'true'`     | Accept `KEY<<DELIMITER` entries. `false` refuses them and writes the `lines` output. |
| `append-to`       | no       | `''`         | Non-secret lines the `lines` output starts with, passed through unchanged. With no entries, `lines` is exactly this value. |

## Outputs

| Name     | Description |
| -------- | ----------- |
| `digest` | SHA-256 over each entry's name and the SHA-256 of its value, in order; empty when `env` is empty. Never a value. |
| `lines`  | `append-to` followed by every entry as one `KEY=VALUE` line. Written only when `allow-multiline` is `false`. Carries secret values — use it inside this job only. |
| `names`  | Newline-separated entry names, never values — for a step that scrubs the values out of files before an upload (`run-maestro-*`'s `redact-env-names`). |
| `count`  | Number of entries parsed. |

## Example

```yaml
- name: Apply build-secrets-env
  id: build-secrets
  uses: rnw-community/mobile-ci/actions/apply-secret-env@v4.0.0 # v4.0.0
  with:
      env: ${{ secrets.build-secrets-env }}
      label: build-secrets-env
```
