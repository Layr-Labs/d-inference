# 049 — Harness and provider verification

Status: **PASS on M3 Max**

Source was synchronized from the Qwen research branch to the M3 Max
before running:

| Check | Result |
|---|---|
| `ArrivalPrefillAccountingTests` | 11/11 pass |
| `BenchmarkArrivalOptionsTests` | 2/2 pass |
| `EngineV2KVBackendGateTests` | 26/26 pass |
| full `swift test` | **2,167 tests / 225 suites pass** |
| `swift build -c release --product darkbloom` | PASS |

The factory suite explicitly verifies the removed chunk/budget env names
cannot retune serving. The accounting suite covers overflow, missing and
invalid rows, all timestamps, `L-1` accounting, checksums, and schema
compatibility.

Artifacts:

- `artifacts/harness-arrival-accounting-final.txt`
- `artifacts/harness-arrival-options-final.txt`
- `artifacts/harness-factory-final.txt`
- `artifacts/provider-full-swift-test-final.txt`
- `artifacts/provider-release-build-final.txt`

Build warnings are pre-existing Swift concurrency/deprecation and
dependency-identity warnings; no build or test failed.
