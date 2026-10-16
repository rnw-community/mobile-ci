# turbo-affected

Detects whether any package in a target set is affected relative to a base
SHA, using `npx turbo@<pinned-version> ls --affected --output=json`. Extracted
verbatim from the detect job proven in production CI: `TURBO_SCM_BASE` drives
the affected computation, and the turbo version is pinned per-consumer via
input rather than resolved against whatever `turbo` happens to be on `PATH`.

**Fails closed.** If the `turbo ls` invocation or the JSON parse fails, the
step exits non-zero and the job fails — a detection failure must never read as
a green "nothing affected, skip" result. Use `always-affected: true` for
non-PR events (push, schedule, workflow_dispatch) where there is no meaningful
base to diff against and the pipeline should simply always run. An empty
`base-sha` reports affected without running turbo.

**Target packages default to the targets' own packages.** When
`target-packages` is empty, the `name` in each `targets[].appDir`'s
`package.json` (relative to the working directory) is used instead, so a
caller that already passes its build targets needs no extra input. An
explicit `target-packages` always wins. Derivation fails closed: empty or
invalid `targets`, a target without `appDir` or at the repository root
(which turbo never lists), or a `package.json` that cannot be read or has no
`name` fails the step. Any target package — derived or explicit — that
`turbo ls` does not list as a workspace package fails the step too, since
turbo could never report it affected.

## Inputs

| Name               | Required | Default   | Description                                                          |
| ------------------- | -------- | --------- | ------------------------------------------------------------------------ |
| `turbo-version`     | no       | `2.10.8`  | Pinned turbo npm version.                                                 |
| `target-packages`   | no       | `''`      | Newline-separated package names; affected if any is in turbo's affected set. Empty derives them from `targets`. |
| `targets`           | no       | `''`      | JSON array of build targets with an `appDir`; read only when `target-packages` is empty. |
| `base-sha`          | no       | `''`      | Base SHA for the affected computation (`TURBO_SCM_BASE`).                |
| `always-affected`   | no       | `false`   | Skip detection and report affected unconditionally.                     |

## Outputs

| Name       | Description                                     |
| ---------- | -------------------------------------------------- |
| `affected` | `true` or `false`.                                  |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/turbo-affected@v1
  id: affected
  with:
      targets: '[{"name":"app","appDir":"apps/mobile"}]'
      base-sha: ${{ github.event.pull_request.base.sha }}
      always-affected: ${{ github.event_name != 'pull_request' }}
```
