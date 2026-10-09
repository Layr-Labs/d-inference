# Contributing To Darkbloom Provider

Contribute provider-local Swift/native code, model support, landing improvements,
tests and documentation here. Read [AGENTS.md](AGENTS.md) and
[documentation rules](docs/AGENTS.md) before changing ownership-sensitive files.

## Choose The Repository

Keep sibling checkouts at `Darkbloom/d-inference` and
`Darkbloom/darkbloom-platform`. Never nest them. For a new workspace:

```bash
git clone --recurse-submodules https://github.com/Layr-Labs/d-inference.git Darkbloom/d-inference
git clone https://github.com/Layr-Labs/darkbloom-platform.git Darkbloom/darkbloom-platform
```

The coordinator/backend, Rust prompt sidecar, consumer console and internal admin
development belongs exclusively in the platform repository. Never implement,
commit, push or upload new backend, console or admin code here. The retained
`console-ui/` snapshot and its existing build/test/hosting configuration do not
change that ownership. Device-local Swift HTTP APIs are provider code, not
the centralized backend. Check your remote, branch and intended diff before
editing or pushing. See the [owner map](docs/developer/navigation.md).

## Develop And Test

Install tools with `mise install`, initialize recursive submodules, and follow
[build](docs/developer/build.md) and [test](docs/developer/test.md).

```bash
make provider-build
make provider-test
make ui-install ui-lint ui-test ui-build
make landing
make docs-impact-check BASE=origin/master
make docs-check
```

Run only the checks appropriate to your change. Never use production services,
credentials or live provider state as test fixtures. New nontrivial behavior and
bug fixes need meaningful regression coverage. Retain native resource, memory,
privacy and cancellation safeguards; do not replace actual execution evidence
with fixture hashes. Public golden vectors and private platform qualification
are separate checks.

## Code And Review

Follow the clean-code, modularity, native safety and independent refactor-pass
requirements in [AGENTS.md](AGENTS.md). Keep public contracts stable, helpers
cohesive, errors actionable and resource ownership explicit. Swift has no
repository-enforced formatter. Landing and the retained console use their own
ESLint configurations; the existing pre-commit hook checks console TypeScript.
Do not include generated binaries, secrets or unrelated changes.

Protocol, telemetry, model-manifest, memory-quotation and installer changes
require coordinated platform review. Review exact revisions and preserve enum
casing and optional fields. Do not copy private implementation into public
fixtures or run a moving platform checkout from provider CI.

## Commits And PRs

Use a focused branch and concise descriptive commits. Every PR commit must be
signed and Verified on GitHub. Inspect status, diff and recent history before an
authorized commit; stage only intended files. Do not force-push or rewrite
published history. Follow the [stacking guide](docs/developer/pull-requests.md)
for signed parent updates and post-squash ancestry repair.

Every PR includes Before/After Mermaid diagrams showing behavior and code flow
(navigation/ownership for docs), concrete checks and their outcomes, known
limitations, and an independent refactor-pass result. Keep draft status while
required checks or operational gates remain unresolved. Do not claim deployment,
release, native parity or full-model qualification from a source cleanup.

### Changelog entries with less merge contention

Put user-visible changes in a small topic-specific `Unreleased` section in
[CHANGELOG.md](CHANGELOG.md); update that section in place. Preserve other
contributors' sections and all historical entries. Do not assign a release
version or claim shipment without a requested release operation.

## Release And Publication

Follow [provider release](docs/operations/provider-release.md) and
[model publication](docs/operations/model-migration.md). External registration
APIs remain supported; backend build/test/deploy does not live here. Release,
model publication, infrastructure, hosting and traffic changes require specific
human approval. Never modify live endpoints or credentials as incidental cleanup.

## License

Contributions are covered by [LICENSE](LICENSE). Keep required attribution and
third-party notices intact. Be respectful, factual and constructive in review.
