# pr-preview-comment

Keeps **one** sticky pull-request comment that several workflows write into,
instead of a new comment per push. `expo-ota-preview.yml` writes the OTA
update sections and `native-dev-release.yml` (with `pr-comment: true`) the
development build sections. Any other workflow can add its own section too.

**One comment, found by a hidden marker.** The comment's first line is
`<!-- mobile-ci:preview -->`. The action pages through the pull request's
comments for one that *starts* with it, so a human comment that quotes the
marker is never taken over. When it finds one (the oldest, if there are
several), it edits that comment in place with `PATCH`. It creates a comment
only when none exists.

**Sections, owned by their writers.** Each section sits between
`<!-- mobile-ci:preview:section:<name>:start -->` and `...:end -->`. A run
replaces only the sections it has a `<name>.md` file for in `sections-dir`.
An empty file removes that section. Every other section is kept as it is.
Sections render in name order. The built-in writers use `<platform>-ota` and
`<platform>-dev-build`, so each platform's native build and OTA update sit
next to each other.

**Concurrent writers.** GitHub's comment API has no compare-and-swap, so
every write is a read-modify-write followed by a verify. The action re-reads
the comment a few seconds after writing it. If another writer's stale copy
has overwritten this caller's sections, it reads, merges and writes again,
up to `max-attempts` times. If it still cannot keep its sections, it fails.
Two writers that both create the comment at once converge on the older one:
the newer is merged into it and deleted.

**Fails closed.** An unreadable comment list, a refused edit (the error names
`pull-requests: write`), a section file named outside `[A-Za-z0-9._-]`, an
empty `sections-dir`, or a comment over GitHub's 65536-character limit all
fail the step. Talks to the REST API with `curl` and `jq` and does not need
`gh`.

## Inputs

| Name           | Required | Default                    | Description |
| -------------- | -------- | -------------------------- | ----------- |
| `pr-number`    | yes      |                            | Pull request number whose comment is updated. |
| `sections-dir` | yes      |                            | Directory of `<section>.md` files. Each replaces that section; an empty file removes it. |
| `title`        | no       | `## Mobile preview`        | Markdown heading at the top of the comment. |
| `token`        | no       | `${{ github.token }}`      | Token with `pull-requests: write` (or `issues: write`). |
| `repository`   | no       | `${{ github.repository }}` | `owner/name` of the pull request's repository. |
| `max-attempts` | no       | `5`                        | Read-modify-write attempts before failing when concurrent writers keep overwriting this caller's sections. |

## Outputs

| Name          | Description |
| ------------- | ----------- |
| `comment-id`  | Id of the sticky comment. |
| `comment-url` | URL of the sticky comment. |

## Example

```yaml
- name: Render my section
  shell: bash
  env:
      SECTIONS_DIR: ${{ runner.temp }}/preview-sections
  run: |
      mkdir -p "$SECTIONS_DIR"
      printf '### Storybook\n\n[Open](https://example.com/pr)\n' > "$SECTIONS_DIR/web-storybook.md"
- uses: rnw-community/mobile-ci/actions/pr-preview-comment@v4.0.0 # v4.0.0
  with:
      pr-number: ${{ github.event.pull_request.number }}
      sections-dir: ${{ runner.temp }}/preview-sections
```

The calling job needs `permissions: pull-requests: write`.
