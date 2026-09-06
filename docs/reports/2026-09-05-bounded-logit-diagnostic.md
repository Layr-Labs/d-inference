# Bounded observation of actual target logits

> Last updated: 2026-09-05 · commit `53e45fc14`

An optional native diagnostic and standalone benchmark flags capture the actual
target decision at one generated position. The source passes 139 native test
functions, 11 benchmark tests and 53 Python tests. Real-model observations remain
pending; the Qwen backend token mismatches remain unresolved.

## Behavior and scope

Native commit `0103f2490730111cd3d9453f6cb7eb27a519cad3` adds a Diagnostics SPI
configuration for one request ID, one zero-based output position and one or two
candidate token IDs. Capture defaults to eight compact records and has a hard
limit of 16. Installation, drain and clear require an idle engine. Nil configuration
constructs no diagnostic tensors.

The capture uses target logits already produced by ordinary, seed, serial and
rectangular MTP execution. Rectangular verification retains its existing fused
top-two result. Records include an independent argmax, top-two values, candidate
values, nonfinite counts and the actual verification position and context.
Float32 bit patterns preserve nonfinite values in valid JSON. Reconciliation
distinguishes confirmed output from rejected speculative suffixes and truncation.

There is no extra model forward or explicit evaluation fence. Diagnostic arrays
join the existing evaluation targets; host collection follows the existing
adaptive step-cost measurement. Additional GPU reductions can still change timing
and subsequent adaptive choices. Trace-on outputs must therefore be compared with
their uninstrumented controls before interpreting any difference.

The standalone benchmark installs capture after warmup, targets the first main
request and drains after its existing idle observation. Missing confirmed records,
budget omissions or invalid vocabulary IDs make the diagnostic inconclusive.
The wrapper requires paired flags, B1 and explicit SSD mode, preserving backend,
MTP, grants, input and existing validation controls. Ordinary invocations retain
their original argument sequence. These flags are absent from the serving CLI.

## Validation

| Scope | Result |
|---|---|
| Native diagnostic and MTP regressions | 139 functions, 143 expanded cases; no failures or skips |
| New native diagnostic coverage | Eight functions, nine expanded cases |
| Benchmark options and idle observation | Three new option tests plus eight existing idle tests pass |
| Wrapper and strict evidence checks | 53 Python tests pass in root and independent review |

Native tests exercise disabled capture, bounded selection, invalid configuration,
ordinary trace-off/on outputs and forward shapes, stateful MTP, real fused top-two
reduction, rejection context and retirement. Root verified 753 native-build and
1,008 benchmark-build source mappings against their resolved source bytes.

The first native attempt failed before compilation because its copied package
omitted executable directories. The second found a missing `try` in a new test
macro. The corrected test and both failed attempts are retained; implementation
and benchmark source were unchanged by that correction.

## Limits and evidence

This diagnostic exports no full vocabulary row, query dtype, device strides,
prompt text or KV/recurrent tensors. It does not establish a numerical cause,
attention accuracy, model parity, performance, default activation or serving CLI
acceptance. Use the [benchmark instructions](../developer/test.md#prefix-cache-benchmark-validation)
with the existing strict model and cache controls.

The [manifest](evidence/bounded-logit-diagnostic-2026-09-05/manifest.json) and
[archive](evidence/bounded-logit-diagnostic-2026-09-05/payloads.tar.gz) preserve
162 payloads (6,404,469 bytes): reviewed source, raw validation, failed attempts,
independent review and applied-source proof. Every archived member was verified.
Compiled executables and model weights are excluded.
Manifest SHA-256: `8dd1d7ecad143bec2f3b3adbb2e7f36708ba70608b586e4e38d18842d5095ef8`.
Archive SHA-256: `9ca690e71a5074c902c0622323aa7bae131d4d3f0feb50132746ba0b38d90a3b`.
