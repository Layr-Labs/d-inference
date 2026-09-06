# Coordinator and provider hot-path cleanup

> Last updated: 2026-09-04 · commit `4d9811f7c`

This report records local refactoring and CPU measurements on the
`optimizations-refactor` worktree, based on master `4d9811f7c`. It measures
request-processing overhead; it does not establish model TTFT, GPU decode
throughput, or production latency gains.

## Changes

| Area | Before | After |
|---|---|---|
| Routing | Temporary candidate lists for preferences, near ties, and equivalent candidates; redundant cost callback and scan counters | In-place preference filtering and allocation-free ranking in `coordinator/registry/candidate_selection.go`; existing admission and tie-break rules preserved |
| Tool arguments | JSON-shaped internal maps and repeated concatenation of the entire accumulated argument | Typed state and `strings.Builder` in `coordinator/api/tool_call_accumulator.go`; wire objects constructed at finalization |
| SSE processing | Nested quote scans; duplicated sanitizer framing; normalization embedded in `consumer.go` | Linear metadata gate, shared sanitizer framing, and focused `sse_normalize.go` |
| Provider request decoding | Four independent template-control JSON parses; local batch items serialized again | Shared `ChatTemplateControls: Decodable`; `LocalChatRequest` decodes the upstream request and extensions from one document |
| Standalone startup | Two full SSD-identity weight hashes even for known SSD-ineligible Qwen models | Configuration-based exclusion via `PrefixCachePolicy.requiresLoadHashBracket`; unknown configurations retain the bracket and connected attestation stays unchanged |
| Inference bridge | Event translation and accounting in one large file; duplicated terminal cleanup | Separate `EngineV2Bridge+Events.swift` and `+Accounting.swift`, shared resource release, and no stop-token replay buffer when nobody consumes it |
| Logprobs and KV API | Decode the chosen token again when it appears among alternatives; deprecated incremental reservation method with no production callers | Reuse chosen-token text/bytes and retain each alternative's probability; remove `increaseReservation` in favor of `resizeReservationBytes` |

The tool accumulator retains sparse/reused indices, stable order, optional
fields, and the 128-call cap. Its typed state eliminates unreachable map-repair
branches. The bridge preserves cancellation usage, typed terminal errors,
reservation ownership, SSD receipt ordering, and teardown errors.

Production source across this change is 101 lines smaller after accounting for
new modules. The large coordinator consumer and provider bridge files shrink
by 262 and 510 lines respectively; much of that code moves into focused files.
Regression tests and benchmark evidence are additional files, not production
code deletion.

## Measurements

Machine: Apple M3 Max. Provider benchmark: Swift 6.3.2, `swiftc -O`, seven
alternating baseline/candidate rounds, median per operation. Routing benchmark:
Go 1.25.0, same binary and fixtures, five samples after the large builds ended.
API comparisons use Go 1.25.0, the same binary and fixtures, and three samples
after the full test runs ended. These are local median CPU timings, not service
latency percentiles.

| Operation | Baseline | Candidate | Result |
|---|---:|---:|---:|
| Template controls, 1,207-byte body | 10.155 µs | 3.285 µs | 3.09× faster |
| Template controls, 131,255-byte body | 290.802 µs | 73.495 µs | 3.96× faster |
| Template controls, 3,145,911-byte body | 6,768.833 µs | 1,695.513 µs | 3.99× faster |
| Rank 350 providers, no cache discount | 3.717 µs | 1.114 µs | 3.34× faster |
| Rank 350 providers, cache discount present | 3.721 µs | 1.114 µs | 3.34× faster |
| Rank 350 providers, allocations | 6,144 B / 2 allocations | 0 B / 0 allocations | Temporary lists eliminated |
| Full 350-provider reservation | 15 allocations | 13 allocations | Timing gain not established |
| Metadata gate, ordinary content chunk | 626.1 ns | 201.3 ns | 3.11× faster |
| Reconstruct 2 KiB tool arguments | 165.602 µs | 144.823 µs | 1.14× faster |
| Reconstruct 16 KiB tool arguments | 2.171 ms | 1.143 ms | 1.90× faster |
| Reconstruct 64 KiB tool arguments | 13.957 ms | 4.608 ms | 3.03× faster |

| Tool-argument fixture | Baseline allocated bytes | Candidate allocated bytes | Reduction |
|---|---:|---:|---:|
| 64 fragments / 2 KiB | 189,074 | 121,105 | 36.0% |
| 512 fragments / 16 KiB | 5,357,817 | 964,385 | 82.0% |
| 2,048 fragments / 64 KiB | 75,890,741 | 3,794,765 | 95.0% |

Reconstruction includes JSON decoding and final wire-object construction, not
just the builder append. The argument body grows by 32 bytes per fragment.
An earlier Go 1.27.1 run showed a 96.9% allocation reduction for the largest
fixture; the table uses the repository-pinned compiler for both arms.

The template benchmark isolates control extraction, including scanning the
request body; it does not time the entire HTTP handler or model generation.
The routing benchmark isolates ranking after candidate construction. Most
reservation work remains outside that function.

The previously audited standalone startup candidate `26b8f0355` was adapted
to this baseline and covered by the provider tests. Its earlier M5 startup
measurements were not rerun here and are not included as new measured gains.

## Validation

- `GOTOOLCHAIN=go1.25.0 go test ./coordinator/...`: all 25 packages with tests pass.
- Registry and routing simulation pass race detection on Go 1.25.0 and 1.27.1.
- Affected API streaming, tool-call, metadata, and Anthropic-emitter race tests
  pass, including 59 targeted cases on Go 1.25.0.
- Provider build and full test command pass: 82 XCTest tests plus a Swift Testing
  run reporting 2,452 tests in 250 suites. Optional live-model cases retain their
  existing environment-based skips.
- The routing oracle checks 1,000 generated candidate pools. Additional baseline
  equivalence checks cover 1,024,000 tool deltas and 100,000 metadata-gate inputs.
- Request-decoding tests compare complete upstream request values and error
  categories/paths, including tools, media, batch items, and malformed controls.
- Hash tests cover exclusion, unknown/malformed configurations, mutation,
  unavailable hashes, and connected attestation behavior.

The shell defaults to Go 1.27.1. Four unrelated JSON-encoding tests failed with
that version and passed with the repository's pinned Go 1.25.0. No encoding
compatibility change was made to accommodate the newer toolchain.

## Reproduction and evidence

Current coordinator benchmarks:

```sh
GOTOOLCHAIN=go1.25.0 go test ./coordinator/registry -run '^$' -bench 'BenchmarkSelectRoutingCandidate|BenchmarkReserveProviderEx' -benchmem -count=5
GOTOOLCHAIN=go1.25.0 go test ./coordinator/api -run '^$' -bench 'Benchmark(StripProviderChatMetadata|ExtractMessageToolArguments)$' -benchmem -count=3
```

The frozen [template-control comparison](../assets/coordinator-provider-hotpaths-20260904/template-controls-benchmark.swift)
contains the baseline four-probe decoder and the candidate decoder used for this
measurement. Build it with `swiftc -O` and run the executable. Output:
[template results](../assets/coordinator-provider-hotpaths-20260904/template-controls-results.txt).

Other evidence: [routing ranking results](../assets/coordinator-provider-hotpaths-20260904/routing-ranking-results.txt),
[routing source manifest](../assets/coordinator-provider-hotpaths-20260904/routing-source-manifest.json),
[baseline full-reservation results](../assets/coordinator-provider-hotpaths-20260904/routing-reserve-before.txt),
[pinned API paired results](../assets/coordinator-provider-hotpaths-20260904/api-paired-results.txt).

The changes remain local to the worktree. This report records no deployment or
public release.
