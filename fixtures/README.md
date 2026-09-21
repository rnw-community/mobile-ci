# fixtures

Minimal, self-contained inputs the repo's own `self-test.yml` runs its actions
against. They exist so a behavioural change can be exercised on the fleet
without a consumer repository standing by.

- `swift-package/` — a two-test Swift Package with no dependencies, used by the
  `fleet-swift-self-test` job to exercise
  [`swift-test`](../actions/swift-test/README.md) end to end (cache key
  computation, `swift test --parallel`, step summary).

There is deliberately **no** `.xcodeproj` fixture: a checked-in `project.pbxproj`
is a large, Xcode-version-sensitive artefact that drifts silently, so
[`xcodebuild-test`](../actions/xcodebuild-test/README.md) is validated against a
real consumer (`vitalyiegorov/pony-labirinth`) instead — see
[AGENTS.md](../AGENTS.md#consumer-validation-on-the-fleet).
