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
   `rnw-community/mobile-ci/actions/<name>@<previous-tag>` self-reference to
   `@vX.Y.Z` — the tag you are about to cut — with a trailing `# vX.Y.Z`
   comment. Self-references live in **both** `.github/workflows/*.yml`
   (reusable workflow → action) and `actions/*/action.yml` (action → action,
   e.g. `run-maestro-android-redroid` → `redroid-container`); a bump loop
   that misses the `actions/` half ships a release whose composite actions
   still call the *previous* release's code. For example, releasing `v1.3.1`
   after `v1.3.0`:

   ```bash
   while IFS= read -r f; do
     perl -pi -e 's{(rnw-community/mobile-ci/actions/[a-z0-9-]+)\@v1\.3\.0(?:\s*#\s*v1\.3\.0)?}{$1\@v1.3.1 # v1.3.1}' "$f"
   done < <(grep -rl 'rnw-community/mobile-ci/actions/' \
     --include='*.yml' .github/workflows actions \
     | grep -v '^\.github/workflows/self-test\.yml$')
   ```

   Then confirm nothing was left behind — this must print nothing:

   ```bash
   grep -rn 'rnw-community/mobile-ci/actions/' --include='*.yml' \
     .github/workflows actions \
     | grep -v '^\.github/workflows/self-test\.yml:' \
     | grep -v '@v1\.3\.1 # v1\.3\.1$'
   ```

   `self-test.yml` is filtered out of both: it matches only because its
   `dry-lint-local-refs` job names the self-reference pattern in a comment
   and a `sed` script, and it carries no self-reference of its own.

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

7. **Verify release self-consistency**: every self-reference-bearing file in
   the tagged commit must point at that same tag — the reusable workflows
   (`ios-maestro.yml`, `android-maestro.yml`, `seed-native-cache.yml`,
   `store-screenshots.yml`; `native-publish.yml` and `native-dev-release.yml`
   have none) **and** the composite actions that call sibling actions
   (`run-maestro-android-redroid/action.yml` → `redroid-container`). Fail
   closed: any reference whose tag or trailing comment does not match the
   release is a broken release, not a warning.

   ```bash
   tag=v1.2.3
   tag_re=$(printf '%s' "$tag" | sed 's/[.[\*^$]/\\&/g')
   check_status=0
   for path in .github/workflows/ios-maestro.yml \
               .github/workflows/android-maestro.yml \
               .github/workflows/seed-native-cache.yml \
               .github/workflows/store-screenshots.yml \
               actions/run-maestro-android-redroid/action.yml; do
     content="$(gh api "repos/rnw-community/mobile-ci/contents/${path}?ref=${tag}" \
       --jq '.content' | base64 -d)"
     if ! printf '%s\n' "$content" | grep -q 'rnw-community/mobile-ci/actions/'; then
       echo "::error::${path}: no self-references found at ${tag}"
       check_status=1
       continue
     fi
     if printf '%s\n' "$content" \
       | grep 'rnw-community/mobile-ci/actions/' \
       | grep -vE "rnw-community/mobile-ci/actions/[a-z0-9-]+@${tag_re}( # ${tag_re})?\$"; then
       echo "::error::${path} has a self-reference not pinned to ${tag}"
       check_status=1
     fi
   done
   exit "$check_status"
   ```

   `$tag_re` escapes regex metacharacters in the tag (dots in `v1.2.3`
   would otherwise match any character, letting a typo like `v1x2x3` pass
   as if it matched `v1.2.3`) — do not interpolate `$tag` directly into
   the `grep -vE` pattern.

   The path list is the fail-closed part: a file that gained a
   self-reference but was never added there would be silently unchecked.
   Refresh it from the working tree before running the loop, using the same
   `grep -rl` (minus `self-test.yml`) as step 1:

   ```bash
   grep -rl 'rnw-community/mobile-ci/actions/' --include='*.yml' \
     .github/workflows actions \
     | grep -v '^\.github/workflows/self-test\.yml$'
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
and `actions/*/action.yml` must point at the exact `vX.Y.Z` tag being cut,
not at `@main` and not at the previous release's tag — see step 1 of the
checklist above and
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

### Validating a not-yet-tagged self-reference on the fleet

The "tag known in advance" pattern above breaks fleet validation
([AGENTS.md#consumer-validation-on-the-fleet](AGENTS.md#consumer-validation-on-the-fleet))
whenever a branch's self-references include one pinned to a `vX.Y.Z` that
does not exist as a tag yet — either because the PR itself introduces a
brand-new self-referenced action, or because the branch was cut from `main`
after `main` already picked up a not-yet-tagged bump. GitHub resolves every
`uses:` in a job during job setup, *before* any step-level `if:` is
evaluated, so the fleet run fails at "Prepare all required actions" with
`Unable to resolve action rnw-community/mobile-ci@vX.Y.Z` — even for a
consumer job that never reaches the guarded step, and even for a consumer
that doesn't use the new feature at all. `actionlint`, `zizmor`, and
`dry-lint-local-refs` all pass on this, because none of them resolve a
`uses:` ref against GitHub; only an actual fleet run surfaces it. This
affected both #103 and #105/#107 (2026-08-31).

Workaround, used successfully on both:

1. Before pushing the branch for fleet validation, push a commit that
   temporarily repoints every not-yet-tagged self-reference on the branch to
   the branch head's full 40-character commit SHA, with a trailing comment
   like `# <branch-name> fleet-validation pin` in place of the `# vX.Y.Z`
   comment (`zizmor`'s ref-pin policy accepts a full SHA, and
   `dry-lint-local-refs`'s `sed` substitution matches SHA-pinned
   self-references the same as tag-pinned ones, so `self-test` stays green).
   **Check for more than one such reference** — #107 correctly re-pinned the
   self-reference its own PR introduced but missed `load-consumer-config`,
   which the branch had inherited from `main` still pinned at the
   not-yet-cut `v1.11.0`.
2. Point the consumer's scratch caller (`suuudokuuu`) at this new head SHA
   and run fleet validation per
   [AGENTS.md#consumer-validation-on-the-fleet](AGENTS.md#consumer-validation-on-the-fleet).
3. Once validation passes, push a further commit restoring every
   SHA-pinned self-reference to its original tag-form pin, byte-identical to
   what it was before step 1, before this PR merges.

Consequence for the release window: once a PR merges to `main` with
tag-form self-references pointing at a tag that does not exist yet, every
affected reusable workflow on `main` is uninvokable by any consumer —
including one floating on `@v1` or `@main` — until that tag is cut. Do not
leave `main` in that state; cut the tag (checklist steps 2–3 above) promptly
after the last PR of a release merges.
