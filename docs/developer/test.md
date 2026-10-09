# Test Provider And Native Contracts

> Last updated: 2026-10-09

Run isolated Swift, native-resource, public-fixture, retained-console and landing tests here.
Backend integration and cross-implementation qualification are platform-owned.
Never point tests at production or overwrite a running provider's state.

## Prerequisites

Use the [source-matched build](build.md), Apple Silicon and the documented Xcode
toolchain for MLX execution. GPU/native tests need exclusive device access and
their real resource bundles; ordinary Python checks do not prove GPU correctness.

## Provider And SDK

```bash
make provider-test
```

The Make target builds test products, stages source-matched metallibs and uses
`scripts/run-provider-tests.sh`. The runner isolates daemon-state and loaded-model
snapshots. Preserve its watchdog, cleanup and state isolation when using a focused
selector. Use `scripts/run-nested-suite.sh` for documented nested Swift Testing
cases and `scripts/run-exclusive-native-gpu-test.sh` for exclusive native work.

The SDK has independent test products under `libs/mlx-swift-lm`. CI validates
native memory ownership, cancellation, media decoding, paged KV and resource
packaging there as well as provider behavior. Preserve all retained lane gates;
do not treat the repository split as permission to skip native regressions.

## Public Fixtures And Private Qualification

Public protocol JSON and prompt golden vectors contain fixed inputs and expected
outputs. Provider tests must load those inputs from provider-owned resources or
`fixtures/`, not from a removed backend tree. Keep exact bytes, attribution,
artifact hashes, enum casing and optional-field omission intact.

Public golden-vector validation means **this implementation matches those fixed
expectations**. It does not run the private Go/Rust implementation, establish
current cross-implementation parity, prove live routing, or certify all supported
models. Private platform qualification must independently run the corresponding
implementation at explicit revisions and record its native/full-model evidence.
Public CI must not clone a moving private branch or silently replace failed
qualification with a hash check. Refresh expected outputs only after review.

The retained console tests still read
`coordinator/tests/protocol/testdata/paged_footprint_wire.json` and
`coordinator/tests/protocol/testdata/process_memory_wire.json`. These two JSON
fixtures are not a retained coordinator implementation or test suite. Preserve
their bytes and agreement with the provider resource copies when changing the
wire contract; run each implementation's checks in its owning repository.

MiMo metadata preparation uses `scripts/prepare-mimo-prompt-fixtures.py` and
provider/native fixture preparation uses `scripts/prepare-mimo-provider-fixtures.py`
and `scripts/prepare-mimo-audio-fixtures.py`. Use their isolated output directories;
small native fixtures are not full-model numerical qualification.

## Focused Tooling Checks

```bash
make benchmark-wrapper-test
python3 scripts/test-docs-impact-check.py
python3 scripts/test-docs-check-historical-links.py
python3 scripts/test-docs-stamp.py
python3 provider-swift/Tests/test_protocol_fixture_resources.py
make docs-impact-check BASE=origin/master
make docs-check
```

Docs-impact coverage tests pin provider-sensitive mappings: configuration,
protocol/public fixtures, privacy, cache storage, native capacity, release/model
publication, console source/packaging, shared console fixtures and CI. One
unrelated doc cannot satisfy every matching rule.
Historical-link checks retain exact provenance rather than treating all missing
files as valid. Final full-tree lint needs intended additions/removals staged
because the checker enumerates tracked files; explicit existing paths can be
checked earlier, without the orphan pass. Neither is a substitute for the final
staged full-tree check.

For SSD write endurance, `scripts/test-ssd-write-budget.sh` runs isolated accounting
checks on macOS. Keep persistent restart, damaged-ledger, clock rollback and
multi-process cases. Native cache tests must also retain missing/replaced-volume,
encryption, epoch, owner-only permissions and no-fallback behavior.

## Retained Console

```bash
make ui-install ui-lint ui-test ui-build
```

`ui-test` runs Vitest; tests cover route handlers, validation, state and protocol
fixtures. `ui-lint` checks `src/` with ESLint. The console CI lane and existing
console-only pre-commit hook remain. `next build` ignores TypeScript errors in
the retained configuration, so it is not a substitute for lint, Vitest or the
separate `npm run typecheck` diagnostic in `console-ui/`. Use only isolated
fixtures and test services, never live accounts or billing credentials. See
[console architecture](../architecture/components/console-ui.md); new console
development remains platform-owned.

## Landing

```bash
make landing
```

This installs locked dependencies, lints, builds and exercises local HTTP routes.
Keep external service calls isolated or explicitly configured to test services;
do not use real billing credentials or production accounts.

## Reporting Results

Report the exact selector, revision, native resources and model identity for
qualification. Distinguish compile-only, fixed vectors, tiny native fixtures,
full-model execution, signed-artifact tests and private platform integration.
Document skips and unavailable hardware honestly. Passing local validation does
not authorize deployment.

## Related

- [Build](build.md)
- [Serving-performance qualification](serving-performance-qualification.md)
- [Historical references](historical-references.md)
- [Provider release](../operations/provider-release.md)
