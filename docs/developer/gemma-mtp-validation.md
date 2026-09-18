# Validate Gemma target and assistant behavior

> Last updated: 2026-09-17 · commit `954f570d1`

Run the supervised Gemma MTP matrix with immutable local target and assistant
snapshots. Keep numerical correctness, production stop behavior and performance
evidence separate.

## Prerequisites

Build the provider tests and matching Metal resources using [Build](build.md).
Reserve one exclusive GPU lane. Keep the target, assistant, quantization,
sampler, source pins and runtime resources fixed across comparisons. The runner
uses cached artifacts only and refuses incomplete or mismatched identities.

## Steps

1. Run the CPU-only supervisor checks from the repository root:

   ```sh
   python3 scripts/test-mtp-metric-contracts.py
   python3 scripts/run-mtp-benchmark.py --self-test-output-safety
   python3 scripts/run-mtp-benchmark.py --self-test-artifact-provenance
   ```

2. Run `MTPMetricContractTests` and `MTPBenchmarkTests` in `provider-swift`.
   Require nonzero test counts and no skipped tests.
3. Run `scripts/run-mtp-benchmark.py` with explicit `--target-path` and
   `--assistant-path` snapshots. Supply `--target-id` and `--assistant-id` when
   a path is outside the Hugging Face cache layout. Select the mode below.

| Mode | Stop behavior | Required evidence |
|---|---|---|
| `raw-parity` | Fixed length, configured stops suppressed | Exact token/terminal evidence; no performance fields |
| `production-correctness` | Target's production EOS/stops | Exact token/terminal evidence and automatic verification; no performance fields |
| `production-performance` | Target's production EOS/stops | Release build, timings and retained positive-depth cost samples for applicable active modes |

4. Preserve the complete report, launch fingerprint, commands, source/artifact
   identities and any failed attempts. A partial checkpoint is not a passing
   matrix. Never quote correctness-mode wall time as throughput.

## Verify

`MTPBenchmarkRunner.validateMetrics` distinguishes completed verification from
retained cost learning. A request or token boundary can cancel a learning window
after real drafts have been verified. Correctness may use actual verification
counters plus tracked acceptance positions when a cost sample is unavailable;
performance still requires the depth/bucket cost evidence. Both modes retain
the exact target-only token and finish-reason comparison.

An automatic work-cap fallback may contain an initial ordinary seed before the
requested batch fills. Positive plans must be bounded by recorded seeds. A
seed-only fallback still requires zero draft proposals, verification rounds,
accepted/emitted speculative tokens, speculative timing and cost residue. It
is not evidence of MTP throughput. The automatic work cap is unchanged.

The Swift checks live in
`provider-swift/Sources/ProviderBenchmark/MTPBenchmarkRunner.swift`; the Python
report checks in `scripts/run-mtp-benchmark.py` mirror them. The regression
fixtures in `MTPMetricContractTests` and `scripts/test-mtp-metric-contracts.py`
reject invented seeds, unexplained positive plans, speculative residue,
out-of-cap work and unsupported cost-evidence claims.

## Troubleshooting

If a performance run has no retained cost sample, use a workload long enough
to measure a complete learning window. Do not increase the automatic work cap,
switch to a serial oracle, suppress production EOS, or weaken token equality
to make a performance report pass. Use a separately labelled correctness run
to investigate execution without making a speed claim.

This matrix does not replace real API/tool/media, cache persistence, memory,
lifecycle or signed/hosted qualification. See [Test](test.md) for those gates.
