# Prefix receipt ownership through the engine event pump

> Last updated: 2026-09-05 · commit `d25296c65`

Successful provider submission now leaves prefix receipts owned by the event pump
through engine terminal. A deterministic real-engine test reproduces the original
premature cleanup; the corrected source passes both new tests and 88 distinct
provider regression functions. A rebuilt connected HTTP rerun remains pending.

## Defect and correction

The [Qwen3.8 HTTP failure](2026-09-05-connected-http3-donation.md) records a completed
SSD donation without a coordinator Ready receipt. In `EngineV2Bridge.submitTokenized`,
the successful-return defer discarded the newly registered receipt before the pump
finished. Later durable publication found no receipt and emitted no callback.
The same defer also completed staged-resource cleanup and discarded resident proof early.

`EngineV2Bridge+Submission.swift` now guards that cleanup with
`pumpOwnsPrefixResources`, set immediately before the nonthrowing `runPump` call.
The existing pump terminal path owns cleanup after that handoff. Each cache still
manages pending durable publication and receipt retention. Exceptional
`retirementTransfer`, pending IDs and their independent defers remain unchanged.

The original submission source SHA-256 is
`7deec47104eff682000eed06562271d124022c0dab7a1d72c0641985710506d9`;
the correction is `41669183e8a69a75cfe6e71b30e4df8173d90082dc29f32b9dada714e985e519`.
The changed bridge test file is
`c44de8a0e5f1afe5b2c0b048bce5ec8b2301cdc9e29dcba1ec253ac1384d70d6`.
These exactly match the reviewed source freeze and actual compiler inputs.

## Validation

`EngineV2BridgePumpReceiptTests` uses a real EngineV2, encrypted complete-checkpoint
store and tiny deterministic tensors. A first-forward gate keeps publication behind
the assertion made after submission returns. With the original production source,
`readyAfterSubmitReturns` observes zero live receipts instead of one, then no durable
callback. Its failure log and original source remain preserved.

With the correction, that test verifies durable files, a Ready callback for 512
tokens, terminal receipt removal and zero staged bytes. The cancellation test
verifies no donor callback and complete receipt/staging cleanup. These directly
cover receipt lifetime and cancellation; they do not add resident-hit or staged-hit
fixtures. Existing admission, cancellation, retirement, receipt ordering, shared
budget, encrypted-store and reslice-unwind suites also pass.

All 14 requested filters pass: 88 unique functions, 92 executions because four
outer-receipt functions appear in overlapping filters. Nothing was skipped or
weakened. The validator compiled against native `a932d38` plus the separately
reviewed bounded-logit diagnostic source, now committed as `0103f24` with identical
source bytes; diagnostics were **nil in both arms**.
That native union, source manifests, dependency overlays and compiler graphs are
retained as provenance; this change contains only the two provider source/test files.
A runner-only symlink-path comparison failure after the successful baseline build
was corrected before testing; the same baseline binary was reused without rebuilding.

Root rehashed all 63 provider-validation payloads and reviewed the result. No real
model or network fixture ran in this validation. Connected publication/routing,
strict model backend parity and release/default promotion remain separate gates.

The [manifest](evidence/prefix-receipt-pump-ownership-2026-09-05/manifest.json) and
[archive](evidence/prefix-receipt-pump-ownership-2026-09-05/payloads.tar.gz) retain 144
payloads (9,641,538 bytes), including source review, baseline/candidate logs and
diagnostic-native provenance. All archive members were verified; compiled binaries
are excluded. Frozen failed HTTP reports remain unchanged.
Manifest SHA-256: `269de91c79df657c723a616a60598414e8c1784012bd2806338addb914d9123f`.
Archive SHA-256: `b091dc779db5bf7a73e1ff49adb1c45926b77a77d2dd2c65f5f5bd3bf330ba86`.
