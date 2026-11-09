# e2e-simlock-install

Installs [`@mobile-ci/e2e-simlock`](../../packages/e2e-simlock/README.md), the
simlock `DeviceProvider` for tester-army e2e suites, into an e2e project's
`node_modules`. The package ships in this repository, not on npm: the action
copies `packages/e2e-simlock` from the very ref the action is pinned to (GitHub
downloads the whole repository at that ref to run any of its actions), so the
package and the workflow that runs it can never disagree on a version.

It copies `package.json` and exactly what that file's `files` lists, replacing
any earlier copy. Run it **after** the project's own install: `npm ci` and its
equivalents replace `node_modules` wholesale, so the step fails closed when
`e2e-dir` has no `node_modules` yet.

`ios-maestro.yml`, `android-maestro.yml` (through
[`e2e-suite`](../e2e-suite/README.md)) and `store-screenshots.yml`'s e2e driver
run it for you. Add it to a pipeline of your own; for local runs,
`scripts/fetch-e2e-simlock.sh <tag> <e2e-dir>` does the same from a pinned tag.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `e2e-dir` | yes | — | The e2e project's directory, relative to the working directory, with its dependencies already installed. |

## Example

```yaml
- name: Install the e2e project
  working-directory: e2e
  run: npm ci --no-audit --no-fund
- uses: rnw-community/mobile-ci/actions/e2e-simlock-install@v4.12.2 # v4.12.2
  with:
      e2e-dir: e2e
```
