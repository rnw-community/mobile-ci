# Release procedure

Modeled on `softprops/action-gh-release` and
`reactivecircus/android-emulator-runner`: an exact `vX.Y.Z` tag per release,
plus a floating major tag (`v1`) that consumers pin to in practice. **No
`CHANGELOG.md`** — by explicit decision, the GitHub Release notes for each
`vX.Y.Z` tag *are* the changelog. Use GitHub's generated release notes
(grouped by PR/label) rather than hand-writing a duplicate summary.

## Checklist

1. **Update internal self-references to the new tag**, as part of the normal
   PR for the release (not a separate step after merge): bump every
   `rnw-community/mobile-ci/actions/<name>@<previous-tag>` self-reference in
   `.github/workflows/*.yml` to `@vX.Y.Z` — the tag you are about to cut —
   with a trailing `# vX.Y.Z` comment. For example, releasing `v1.3.1` after
   `v1.3.0`:

   ```bash
   for f in .github/workflows/ios-maestro.yml .github/workflows/android-maestro.yml .github/workflows/seed-native-cache.yml; do
     perl -pi -e 's{(rnw-community/mobile-ci/actions/[a-z0-9-]+)\@v1\.3\.0(?:\s*#\s*v1\.3\.0)?}{$1\@v1.3.1 # v1.3.1}' "$f"
   done
   ```

   Get this merged to `main` via the normal PR/review/CI flow (see
   [Self-references](#self-references) below for why the tag can be named in
   advance). Do not tag a commit whose self-references still point at the
   previous release.

2. **Verify `self-test` is green** on the commit you intend to tag —
   `actionlint`, `zizmor`, and `dry-lint-local-refs` all passing on `main` at
   that exact SHA. Do not tag a commit whose `self-test` run you have not
   personally checked.

3. **Tag the exact release**, from that verified commit:

   ```bash
   git tag -a v1.2.3 -m v1.2.3
   git push origin v1.2.3
   ```

4. **Create the GitHub Release with generated notes**:

   ```bash
   gh release create v1.2.3 --generate-notes --title v1.2.3
   ```

   Review the generated notes before confirming; edit only to fix
   mis-categorized PRs, not to add a hand-written summary (see the no-
   `CHANGELOG.md` decision above — the generated notes are the record).

5. **Move the floating major tag** (`v1`) to point at the same commit as the
   new exact tag — force-move, the same convention `actions/checkout`,
   `actions/setup-node`, and most official GitHub Actions follow:

   ```bash
   git tag -f v1 v1.2.3
   git push -f origin v1
   ```

6. **Verify both refs peel to the same commit**:

   ```bash
   git rev-parse v1.2.3^{commit}
   git rev-parse v1^{commit}
   # both must print the identical SHA
   ```

7. **Verify release self-consistency**: the tagged commit's own
   self-reference-bearing workflows (`ios-maestro.yml`, `android-maestro.yml`,
   `seed-native-cache.yml` — `native-publish.yml` and `native-dev-release.yml`
   have no self-references) must point at that same tag. Fail closed: any
   reference whose tag or trailing comment does not match the release is a
   broken release, not a warning.

   ```bash
   tag=v1.2.3
   check_status=0
   for workflow in ios-maestro android-maestro seed-native-cache; do
     content="$(gh api "repos/rnw-community/mobile-ci/contents/.github/workflows/${workflow}.yml?ref=${tag}" \
       --jq '.content' | base64 -d)"
     if ! printf '%s\n' "$content" | grep -q 'rnw-community/mobile-ci/actions/'; then
       echo "::error::${workflow}.yml: no self-references found at ${tag}"
       check_status=1
       continue
     fi
     if printf '%s\n' "$content" \
       | grep 'rnw-community/mobile-ci/actions/' \
       | grep -vE "rnw-community/mobile-ci/actions/[a-z0-9-]+@${tag}( # ${tag})?\$"; then
       echo "::error::${workflow}.yml has a self-reference not pinned to ${tag}"
       check_status=1
     fi
   done
   exit "$check_status"
   ```

8. **Smoke-check one consumer pipeline** against the new tag before calling
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
versioning policy.

## Self-references

Every release, self-references in this repo's own `.github/workflows/*.yml`
must point at the exact `vX.Y.Z` tag being cut, not at `@main` and not at the
previous release's tag — see step 1 of the checklist above and
[CONTRIBUTING.md#self-references](CONTRIBUTING.md#self-references). This is
the "tag name known in advance" pattern: the release tag does not exist yet
when the self-reference update is committed, but the tag name is fixed by
this procedure, and `git tag` on this repo's own commit is created from that
same commit immediately after. `self-test`'s `dry-lint-local-refs` job
rewrites these self-references to relative paths before schema-checking
them, so a not-yet-existent tag never has to actually resolve during CI on
the release PR.

The floating major tag (`v1`) is a separate, deliberately mutable pointer
used only by *consumers* who choose to float — it is force-moved in step 5
above and is never what the self-references in this repo point at.
