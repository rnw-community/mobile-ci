# Contributing

## Agents

[AGENTS.md](AGENTS.md) is the canonical instructions file for AI agents and
humans alike working on this repo — read it before making changes. It
includes the rule that every bot comment on a PR (CI bots, review bots,
Dependabot, code scanners) must be addressed: fixed if valid, replied to
with an explanation if not; never left unanswered or silently ignored.

## Versioning

This repo follows semver on git tags (`v1.2.3`), plus a sliding major tag
(`v1`) that consumers should pin to in their `uses:` lines
(`rnw-community/mobile-ci/actions/build-ios-app@v1`). The sliding tag is
force-moved to the latest compatible release after each publish, the same
convention `actions/checkout`, `actions/setup-node`, and most of the official
GitHub Actions follow. Pin to an exact `vX.Y.Z` tag instead of `v1` only if
you need to freeze against upstream drift entirely.

**Pre-release status:** `v1` has not been cut yet. The action catalog and
reusable workflows here were extracted from a canary pipeline; the `v1` tag
will be created once that source pipeline's canaries are proven green (see the
root `README.md` for details). Until then, consumers pin to `@main` at their
own risk — `main` can change without a deprecation window.

Breaking changes to an action's inputs/outputs or a reusable workflow's inputs
bump the major version. Additive inputs with sensible defaults, new actions,
and bugfixes that do not change existing behavior are minor/patch. See
[RELEASE.md](RELEASE.md) for the exact tag-and-publish procedure.

## Marketplace stance

This repo is a monorepo of path-referenced composite actions
(`actions/<name>/action.yml`), not a single top-level action. GitHub
Marketplace can only list a repository's root `action.yml` — a subdirectory
action cannot be listed independently. `github/codeql-action` and
`expo/expo-github-action` are structured the same way and document the same
stance for the same reason: this repo is deliberately not Marketplace-listed.
Consumers reference actions and reusable workflows directly via
`uses: rnw-community/mobile-ci/actions/<name>@<ref>` /
`uses: rnw-community/mobile-ci/.github/workflows/<name>.yml@<ref>`, the same
way they already reference any other subdirectory action or reusable
workflow on GitHub.

## Third-party actions

Every third-party `uses:` (i.e. not `rnw-community/mobile-ci/...`) is pinned
to a full commit SHA with a `# vX.Y.Z` trailing comment noting the tag that
SHA corresponds to. Dependabot (`.github/dependabot.yml`) opens PRs to bump
these pins; do not hand-edit a SHA without also updating its version comment.

## Self-references

The reusable workflows under `.github/workflows/` invoke this repo's own
composite actions via the full `rnw-community/mobile-ci/actions/<name>@<ref>`
form (a relative `./actions/<name>` reference only resolves against whatever
is checked out in the *caller's* job, not this repo, so it cannot be used
here).

The pre-`v1` policy of floating these self-references on `@main` is over:
now that `v1.x` releases exist, a consumer pinning a reusable workflow to a
tag or commit SHA expects that pin to freeze the *entire* call graph,
including the actions the workflow calls internally. Self-references
therefore pin to the exact `vX.Y.Z` tag of the current release (e.g.
`rnw-community/mobile-ci/actions/build-ios-app@v1.3.1 # v1.3.1`), and are
bumped to the new tag as part of the release PR for every release — see
[RELEASE.md](RELEASE.md#self-references) for the exact procedure. Unlike
third-party `uses:`, self-references pin to a tag rather than a commit SHA:
the tag is created from the very commit the self-reference update is part
of, so pinning to a SHA would be chicken-and-egg (the SHA is not known until
after the commit exists), and RELEASE.md forbids ever moving a release tag
once cut — making the tag effectively as immutable as a SHA for this
in-repo, single-release-procedure use.

## Validating changes locally

```bash
brew install actionlint shellcheck
pip install --user zizmor
actionlint -color
shellcheck <changed .sh files / run: blocks extracted as needed>
zizmor --config .github/zizmor.yml .github/workflows actions
```

`actionlint` walks `.github/workflows/**` and, for any step using a local
relative path, schema-checks the referenced `actions/*/action.yml` too. The
`self-test.yml` workflow's `dry-lint-local-refs` job additionally rewrites the
reusable workflows' self-references to relative paths in a scratch copy so
their composite-action schemas are checked in CI as well — reproduce that
locally by running the same `sed` substitution described in that job before
invoking `actionlint`. `zizmor` is CI's static-analysis gate for the
workflows and actions themselves (see the `zizmor` job in `self-test.yml`
for the pinned version); run it with the same `--config` flag CI uses so
findings match.

## Adding or changing an action

- One composite action per directory under `actions/`, with `action.yml` plus
  a `README.md` documenting inputs, outputs, and one example.
- No code comments in `action.yml` beyond what a reader could not get from a
  descriptive step `name:` — prefer renaming steps/inputs over explaining them.
- Keep `run:` blocks POSIX-shell-compatible and `shellcheck`-clean.
- Any PR that adds, removes, renames, or changes the default of an
  `action.yml` input/output must update that action's `README.md` input/
  output table in the same PR — a README that drifts from its `action.yml`
  is a bug, not a follow-up.
