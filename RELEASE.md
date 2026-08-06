# Release procedure

Modeled on `softprops/action-gh-release` and
`reactivecircus/android-emulator-runner`: an exact `vX.Y.Z` tag per release,
plus a floating major tag (`v1`) that consumers pin to in practice. **No
`CHANGELOG.md`** — by explicit decision, the GitHub Release notes for each
`vX.Y.Z` tag *are* the changelog. Use GitHub's generated release notes
(grouped by PR/label) rather than hand-writing a duplicate summary.

## Checklist

1. **Verify `self-test` is green** on the commit you intend to tag —
   `actionlint`, `zizmor`, and `dry-lint-local-refs` all passing on `main` at
   that exact SHA. Do not tag a commit whose `self-test` run you have not
   personally checked.

2. **Tag the exact release**, from that verified commit:

   ```bash
   git tag -a v1.2.3 -m v1.2.3
   git push origin v1.2.3
   ```

3. **Create the GitHub Release with generated notes**:

   ```bash
   gh release create v1.2.3 --generate-notes --title v1.2.3
   ```

   Review the generated notes before confirming; edit only to fix
   mis-categorized PRs, not to add a hand-written summary (see the no-
   `CHANGELOG.md` decision above — the generated notes are the record).

4. **Move the floating major tag** (`v1`) to point at the same commit as the
   new exact tag — force-move, the same convention `actions/checkout`,
   `actions/setup-node`, and most official GitHub Actions follow:

   ```bash
   git tag -f v1 v1.2.3
   git push -f origin v1
   ```

5. **Verify both refs peel to the same commit**:

   ```bash
   git rev-parse v1.2.3^{commit}
   git rev-parse v1^{commit}
   # both must print the identical SHA
   ```

6. **Smoke-check one consumer pipeline** against the new tag before calling
   the release done — re-point a real consumer's workflow (or a scratch
   branch of one) at `@v1` (or the exact `@v1.2.3`) and confirm its next run
   is green. A green `self-test` on this repo proves the schemas are
   internally consistent; it does not prove a real consumer's `targets`/
   `flows-dir`/secrets wiring still resolves against the new tag.

## Breaking vs. non-breaking

Breaking changes to an action's inputs/outputs or a reusable workflow's
inputs bump the major version (and get called out first in the generated
notes' relevant PR titles/labels). Additive inputs with sensible defaults,
new actions, and bugfixes that do not change existing behavior are
minor/patch. See [CONTRIBUTING.md](CONTRIBUTING.md#versioning) for the full
versioning policy, including the pre-`v1` caveat.

## Self-references

Before cutting the *first* `v1` tag, update every
`rnw-community/mobile-ci/actions/<name>@main` /
`rnw-community/mobile-ci/.github/workflows/<name>.yml@main` self-reference in
this repo's own `.github/workflows/*.yml` to `@v1`, in the same commit that
gets tagged — see [CONTRIBUTING.md#self-references](CONTRIBUTING.md#self-references).
For every release after that, self-references stay on `@v1`; only the
floating tag itself moves (step 4 above).
