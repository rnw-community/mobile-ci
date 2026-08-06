# Security policy

## Reporting a vulnerability

Please report security vulnerabilities privately via
[GitHub Security Advisories](https://github.com/rnw-community/mobile-ci/security/advisories/new)
on this repository, rather than filing a public issue. Include the affected
action/workflow, the version or commit SHA you were pinned to, and enough
detail to reproduce. We will acknowledge new reports and coordinate a fix and
disclosure timeline with you through the advisory.

## Self-hosted-runner threat model

Every reusable workflow and composite action in this repo assumes it runs on
a self-hosted fleet whose runners are trusted compute owned by whoever
adopts this catalog — the security boundary this repo defends is "a
consuming repo's own workflow YAML controls what runs", not "an untrusted
pull_request from a fork can safely execute code on the fleet". Consumers
that trigger these workflows from `pull_request` events on a public repo
are responsible for their own fork-PR gating (e.g. requiring approval before
a workflow run on a self-hosted runner, per GitHub's own guidance); nothing
in this repo can compensate for a consumer wiring an untrusted trigger
directly into a self-hosted job. Within that boundary, this repo pins every
third-party `uses:` to a full commit SHA, fails closed on ambiguous internal
state (see e.g. `turbo-affected`'s and `build-env`'s parsing), and always
tears down the ephemeral state it creates (booted simulators, Redroid
containers, temp-file signing credentials) in `if: always()` steps — see
[CONTRIBUTING.md](CONTRIBUTING.md) for the pinning convention and
[docs/self-hosted-runners.md](docs/self-hosted-runners.md) for host
provisioning.
