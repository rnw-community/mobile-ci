# xcodebuild-affected-tests

Turns a pull request's changed files into the `only-testing` list that covers
them, so a PR runs the tests its change can break instead of the whole suite.
The output feeds [`xcodebuild-test`](../xcodebuild-test/README.md)'s existing
`only-testing` input — which is also the list `shard-count` shards — so nothing
else in the lane changes.

**It never narrows a run it cannot account for.** A changed file no entry
claims, a touched full-suite path, any event that is not a pull request
(`base-ref`/`head-ref` do not override that), an empty diff, or a base ref
the checkout cannot reach all select `all`, and `all` means an empty
`only-testing`, which is exactly how `xcodebuild-test` spells "the whole
scheme". A map that is malformed — not an array, an entry with no tests, a test
identifier `xcodebuild` would read as a flag — fails the step instead, because
that is a configuration defect and not a fact about the diff.

## The map file

A JSON file, resolved against `working-directory`, holding an array of entries. Each entry gives
the globs it owns and the test identifiers those paths are covered by:

```json
[
    {
        "paths": ["Sources/Maze/**", "Sources/Maze.swift"],
        "tests": ["PonyUITests/MazeTests"]
    },
    {
        "paths": ["Sources/Menu/**"],
        "tests": [
            "PonyUITests/MenuTests/testStart",
            "PonyUITests/MenuTests/testResume"
        ]
    },
    {
        "paths": ["Resources/**/*.json"],
        "tests": ["PonyUITests/LevelLoadingTests"]
    }
]
```

- A test identifier is `Target`, `Target/Class` or `Target/Class/testMethod` —
  the same shape `xcodebuild -only-testing:` takes. Any of them is safe to
  select: the multiline output uses a random delimiter, so an identifier that
  happens to look like one cannot truncate the list.
- Globs are matched against repository-relative paths: `*` and `?` stop at a
  `/`, `**/` spans directories, everything else is literal. A directory is
  written `Dir/**`, never bare `Dir`.
- A file may be claimed by several entries; the union runs, deduplicated, in
  changed-file order and then map order.
- **There is no "these paths need no tests" entry.** An entry with an empty
  `tests` array is refused: leave a path unmapped and it widens the run to the
  full suite, which is the honest answer for "nothing here knows what covers
  it".
- **The map file is always a full-suite path.** A pull request that edits the
  map is judged by the map it just changed, so a mapping it removed would
  orphan the very files it stopped covering. Any change to `map-file` runs
  everything; the map must therefore be tracked by git, and an untracked one
  fails the step.
- `full-suite-paths` is the other half of the contract: the workflow that runs
  the tests, the `.xcodeproj`, the test target's own sources. A change to what
  runs the tests is never an affected-tests decision.

## Inputs

| Name                | Required | Default | Description                                                                 |
| ------------------- | -------- | ------- | ----------------------------------------------------------------------------- |
| `map-file`          | yes      | —       | Path to the JSON map, resolved against `working-directory` (not the repository root when they differ). |
| `base-ref`          | no       | `''`    | Commit the diff starts from. Empty resolves to the pull request's base SHA.    |
| `head-ref`          | no       | `''`    | Commit the diff ends at. Empty resolves to the pull request's head SHA.        |
| `full-suite-paths`  | no       | `''`    | Globs that force the full suite when touched: one per line, or space-separated on a single line. Write a glob containing a space (`My App.xcodeproj/**`) on its own line. |
| `fallback`          | no       | `all`   | `all` runs the full suite when the changed files cannot be determined; `fail` fails the step. |
| `working-directory` | no       | `.`     | Directory `map-file` and the git repository resolve against.                   |

## Outputs

| Name           | Description                                                                 |
| -------------- | ----------------------------------------------------------------------------- |
| `only-testing` | Newline-separated test identifiers, empty when `mode` is `all`.                |
| `mode`         | `affected` when the list is a selection, `all` when the full suite runs.       |

The step summary lists every changed file next to what it selected, and states
why the mode is what it is.

## Checkout depth

The diff is `git diff --name-only $(git merge-base <base> <head>) <head>`
inside the checkout, so the base commit has to be **in** it. With
`actions/checkout`'s default `fetch-depth: 1` it is not, and every run falls
back to the full suite with a warning. Check out with `fetch-depth: 0` (or
enough history to reach the base) in the job that calls this action.

## Example

```yaml
- uses: actions/checkout@v6
  with:
      fetch-depth: 0

- id: affected
  uses: rnw-community/mobile-ci/actions/xcodebuild-affected-tests@v2
  with:
      map-file: ci/affected-tests.json
      full-suite-paths: |
          **/*.pbxproj
          .github/workflows/**
          PonyUITests/Support/**

- uses: rnw-community/mobile-ci/actions/xcodebuild-test@v2
  with:
      project: Pony.xcodeproj
      scheme: Pony
      mode: test
      destination-id: ${{ steps.simulator.outputs.udid }}
      only-testing: ${{ steps.affected.outputs.only-testing }}
```
