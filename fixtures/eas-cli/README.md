# eas-cli output fixtures

Real `--json` output (and the stderr of a "not found") of the eas-cli commands
`eas-update`, `eas-channel-fingerprint` and `eas-channel-cleanup-reusable.yml`
parse, one directory per eas-cli version: 20.5.1 (this repo's default pin),
21.8.0 and 25.2.0. Recorded 2026-10-19 against the public
`vitalyiegorov/suuudokuuu` EAS project (Expo SDK 58, fingerprint runtime
policy) by a scratch workflow that published to a throwaway channel, read it
back with each version, and deleted it.

`tests/eas-cli-fixtures_test.sh` feeds every version directory to the real step
scripts. To cover a new eas-cli version, record the same files with it:

```bash
e() { npx --yes "eas-cli@$v" "$@" --json --non-interactive; }
e update --channel "$c" --message fixture --platform all  > update.json
e channel:view "$c"                                       > channel-view.json
e channel:list --limit 3 --offset 0                       > channel-list.json
e update:list --branch "$c" --platform ios --limit 1      > update-list.json
npx --yes "eas-cli@$v" update:view "$ios_group" --json    > update-view.json
e build:list --channel "$c" --platform android --status finished --limit 1 > build-list.json
e channel:view "$c-missing" 2> channel-view-missing.err
e branch:delete "$c-missing" 2> branch-delete-missing.err
```

`update:view` takes no `--non-interactive`, and `build:delete` no `--json`;
`tests/lib/eas-cli-contract.sh` makes every eas-cli stub reject both.
