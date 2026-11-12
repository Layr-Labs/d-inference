# Prospective registered short-parity audit

This private CPU checker audits the new two-record short-parity output for the exact registered 9B and 27B profiles. It was written and tested before any actual output from that mode existed. The attempted preceding tiny regression stopped at its external battery check before invoking the parent or native process. No model payload, live native process or candidate result was accessed by this checker.

The copied frozen parent contract validates complete record order, scope, raw 3+1 token history and UUID/request/admission/source joins. The checker separately parses numerical JSON with the established signed-zero convention: Swift's integer spelling `-0` is retained as floating negative zero inside values. Nine numerical helpers are extracted byte-for-byte from the existing frozen tiny recorder oracle, including full-vocabulary Float32-to-BF16 representability and byte-hash reconstruction. Their unused tiny-only entry is not imported or widened.

Expected full source layout and state geometry come from the existing pinned registered metadata. Both full rows from the baseline and both rows from the comparison must reconstruct to their claimed raw SHA256 and compare byte-for-byte. At frontiers 2, 3 and 4, every baseline state entry must have the exact registered global layer/component ordering, shape, dtype and byte count. State, frame and full-baseline aggregate fingerprints are independently replayed and bound to the comparison. The source-defined Int32 position-offset hashes are independently derived. Quantized weight values and non-offset state payloads are not exposed and are not independently compared.

The 9B state has 72 entries and logical totals 51,576,864 / 51,609,632 / 51,642,400 bytes. The 27B state has 144 entries and totals 154,075,200 / 154,140,736 / 154,206,272 bytes. These logical sizes are not an allocator or process-peak estimate. Model-specific geometry was separately source-reviewed before checker implementation; that review is pinned in the manifest.

No successful audit by itself establishes native lifetime, full stage-inventory replay, resource measurements, Plan/profile JSON serialization, provider eligibility, physical two-machine execution or throughput. It must be interpreted alongside the original guarded parent, source and bundle evidence. The parent status is never rewritten by this checker. A passed fabricated fixture is not evidence of a native model run. The fixture intentionally demonstrates that a coherently re-sealed opaque recurrent-state digest cannot establish raw state-value parity.

Run with the saved original token files and an explicitly supplied complete stdout pin:

```sh
python3 -B audit_short_parity.py \
  --stdout /ABS/COMPLETE/stdout.jsonl --stdout-sha256 LOWERCASE_SHA256 \
  --tokens-file /ABS/prompt.json --tokens-sha256 LOWERCASE_SHA256 \
  --teacher-tokens-file /ABS/teacher.json --teacher-tokens-sha256 LOWERCASE_SHA256 \
  --profile registered_qwen35_9b --output /ABS/NEW/audit.json
```

`--retained-metadata` can relocate the shared fixture but cannot change its pin. Output must be new; success and failure both retain a mode-600 receipt. Raw stdout remains bounded by the frozen 64 MiB total and 32 MiB per-record contract. Duplicate/nonfinite JSON and incomplete output are refused.

Fifteen root-authored fabricated CPU tests passed in 6.871 seconds. They cover both profiles, all full-vocabulary rows, native `-0`, sign-bit mismatch, a coherently rehashed different row, nonfinite/Boolean/non-BF16 values, truncated rows, re-sealed geometry/coverage/offset errors, aggregate joins, full source layout, strict optional-field omission, raw history pins and failure receipt preservation. Real subprocess and network launches are blocked in the fixtures. New checker source has root review and pinned earlier numerical/state-source reviews; an additional peer review of this complete new checker remains pending.
