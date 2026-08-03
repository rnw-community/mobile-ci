# Contributing

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
root `readme.md` for details). Until then, consumers pin to `@main` at their
own risk — `main` can change without a deprecation window.

Breaking changes to an action's inputs/outputs or a reusable workflow's inputs
bump the major version. Additive inputs with sensible defaults, new actions,
and bugfixes that do not change existing behavior are minor/patch.

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
here). These self-references currently point at `@main`; update them to `@v1`
in the same commit that cuts the `v1` tag.

## Validating changes locally

```bash
brew install actionlint shellcheck
actionlint -color
```

`actionlint` walks `.github/workflows/**` and, for any step using a local
relative path, schema-checks the referenced `actions/*/action.yml` too. The
`self-test.yml` workflow's `dry-lint-local-refs` job additionally rewrites the
reusable workflows' self-references to relative paths in a scratch copy so
their composite-action schemas are checked in CI as well — reproduce that
locally by running the same `sed` substitution described in that job before
invoking `actionlint`.

## Adding or changing an action

- One composite action per directory under `actions/`, with `action.yml` plus
  a `README.md` documenting inputs, outputs, and one example.
- No code comments in `action.yml` beyond what a reader could not get from a
  descriptive step `name:` — prefer renaming steps/inputs over explaining them.
- Keep `run:` blocks POSIX-shell-compatible and `shellcheck`-clean.
