# turbo-affected

Detects whether any package in a target set is affected relative to a base
SHA, using `npx turbo@<version> ls --affected --output=json`. Extracted
verbatim from the detect job proven in production CI: `TURBO_SCM_BASE` drives
the affected computation, and the turbo version is an exact version, never
whatever `turbo` happens to be on `PATH`.

**Turbo version defaults to the repository's own turbo.** An empty
`turbo-version` resolves, from the working directory and in this order:
`node_modules/turbo/package.json` (when dependencies are already installed),
then the locked version in `pnpm-lock.yaml` (the root importer's `turbo`, or
the single `turbo@` package key), `package-lock.json`, `npm-shrinkwrap.json`,
`yarn.lock` (v1 and berry), `bun.lock`, then an exact (not a range) `turbo` in
the root `package.json`. A source that locks several turbo versions is
skipped with a notice. With none found, `2.10.8` runs and a `::notice::` says
so. An explicit `turbo-version` always wins. Any version — explicit or
resolved — must be an exact semver version, or the step fails before turbo
runs. A pinned turbo older than the repository's own would otherwise reject
newer `turbo.json` keys and fail every pull request.

**Fails closed.** If a `turbo ls` invocation exits non-zero or prints no JSON,
an `::error::` names the turbo version and carries turbo's stderr, and the
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

**Exempt paths skip detection for docs-only pull requests.** With
`exempt-paths` set (e.g. `docs/**`, `**/*.md`, `apps/website/**`, one per
line or comma-separated), a pull request whose every file changed between
`base-sha` and `HEAD` (`git diff --no-renames --name-only base...HEAD`)
matches one of these `glob`-magic pathspecs, relative to the repository
root, reports `affected=false` without running turbo; the changed files and
the globs are logged. `*` does not cross `/`, so use `**/*.md` for Markdown
anywhere. A single non-exempt file, an empty diff, or a diff git cannot
compute (missing base object; logged as a `::warning::`) runs normal turbo
detection instead, which keeps its fail-closed semantics. `always-affected`
and an empty `base-sha` still win.

**Trigger paths run detection-free for files turbo cannot see.** turbo only
attributes a change to the workspace package containing it, so a file outside
every package (the calling workflow, a `.github/` config, a root script the
pipeline reads) never makes a target affected. With `trigger-paths` set, a
change to any file matching one of its globs (same pathspec rules as
`exempt-paths`; a rename counts at both paths) reports `affected=true` without
running turbo, and the matching files are logged. `**` makes every pull
request affected, even one whose diff is empty, which is what an empty `target-packages` meant before
v3.3.0 started deriving it from `targets`. Trigger paths are checked before `exempt-paths`, so a file
matching both runs the pipeline. A diff git cannot compute reports
`affected=true` with a `::warning::`, since no match cannot be proven.
`always-affected` and an empty `base-sha` still win.

**A force label overrides detection.** With `force-label` set and that label
on the triggering pull request (read from the event payload at
`GITHUB_EVENT_PATH`), the step reports `affected=true` and `forced=true` with a
`::notice::`, before `always-affected`, `trigger-paths`, `exempt-paths` or
turbo are considered. Any other event, or a pull request without the label,
reports `forced=false` and detects as usual. An event payload that cannot be
read while `force-label` is set fails the step. Add `labeled` to the caller's
`pull_request` types so adding the label starts a run.

## Inputs

| Name               | Required | Default   | Description                                                          |
| ------------------- | -------- | --------- | ------------------------------------------------------------------------ |
| `turbo-version`     | no       | `''`      | Exact turbo npm version. Empty resolves the repository's own turbo (see above), else `2.10.8`. |
| `target-packages`   | no       | `''`      | Newline-separated package names; affected if any is in turbo's affected set. Empty derives them from `targets`. |
| `targets`           | no       | `''`      | JSON array of build targets with an `appDir`; read only when `target-packages` is empty. |
| `exempt-paths`      | no       | `''`      | Newline- or comma-separated pathspec globs relative to the repository root (e.g. `docs/**`, `**/*.md`). When every file changed since `base-sha` matches one, reports `false` without running turbo. |
| `trigger-paths`     | no       | `''`      | Newline- or comma-separated pathspec globs relative to the repository root (e.g. `.github/workflows/e2e.yml`, `**`). When any file changed since `base-sha` matches one, reports `true` without running turbo. Wins over `exempt-paths`. |
| `base-sha`          | no       | `''`      | Base SHA for the affected computation (`TURBO_SCM_BASE`).                |
| `always-affected`   | no       | `false`   | Skip detection and report affected unconditionally.                     |
| `force-label`       | no       | `''`      | Pull request label that forces `affected=true` (and `forced=true`) without detection. Empty never forces. |

## Outputs

| Name       | Description                                     |
| ---------- | -------------------------------------------------- |
| `affected` | `true` or `false`.                                  |
| `turbo-version` | The turbo version detection ran; empty when turbo did not run (`always-affected`, empty `base-sha`). |
| `forced` | `true` when `force-label` was on the pull request and forced `affected=true`, else `false`. |

## Example

```yaml
- uses: rnw-community/mobile-ci/actions/turbo-affected@v4.3.0 # v4.3.0
  id: affected
  with:
      targets: '[{"name":"app","appDir":"apps/mobile"}]'
      base-sha: ${{ github.event.pull_request.base.sha }}
      always-affected: ${{ github.event_name != 'pull_request' }}
```
