# Bounded checks and next fixture plan

## Executed in this package

`python3 derive.py --output derived` passed: seven bounded metadata/header inputs,29 cuts, two complete mapping examples, four state vectors. No model constructor, payload reader, compiler, remote call or tokenizer execution was used.

`python3 -m unittest -v test_contract` passed11 methods. It checks the authentic header/index join; explicit replica accounting; destination injectivity and global layer coverage at every cut; non-period-aligned cut and quantization relocation; exact expert/shared/attention shape distinction; short-request fixed ring charge and separate K/V; wrapped frontier versus retained span; wrong global geometry/KV sharing/PLE/topK/expert override refusals; changed index/missing tensor/span refusal; same-byte-count wrong expert shape refusal; invalid request/cut/duplicate JSON refusal. See [checks.json](checks.json) for the direct tool receipt and exact tested source pins.

These tests qualify this private pure mapper only. They do not compile Swift, test MLX dtypes, observe kernel dispatch or establish parameter payload values.

## Next source/Foundation checks (not run)

Port the closed mapper into small Swift value types and replay the generated cut12/cut15/all-cut JSON values. Decode the full real configuration with existing `Gemma4Configuration`; assert global30 and all120 overrides survive while local policy paths move. Call only pure policy predicates: topology, safe quantization, last-query final29. Test stage-count substitution, expert policy override, full/sliding phase mismatch, accidental replication of a non-embedding tensor, missed/extra destination, mixed replica descriptor identity, arithmetic overflow, and stale config hash.

Source-preservation checks should bind the original Qwen model/plan/state controls and compare old fingerprints and snapshot bytes after shared extraction. Do not instantiate Gemma during a claimed Foundation-only test: `SwitchGLU` custom activation construction can evaluate a tiny native probe.

## Actual tiny model checks (not run)

Use a separately defined bounded fixture authority and deterministic whole-source weights, not a forged registered30-layer production profile. Build the whole ordinary Gemma text model and both ranged stages from the same global-name source. Use small full/sliding geometry, two or more periods, a non-period cut, tied embeddings, shared FFN and routed MoE. Production kernel eligibility must correctly remain false for that tiny topology.

Compare whole versus two-stage residual/logits through prompt chunks and multi-token greedy decode, including a window wrap. Require rank0 boundary row count equal the complete chunk; exercise final tail/last-query on/off with only the true final global layer narrowing. Compare every retained K/V tensor in temporal order, absolute device offsets and global state join. Test k_eq_v true with different K/V transforms; a deliberately shared K/V object must fail. Confirm rank1 never applies ingress scaling and both tied replicas have the same source values.

Exercise empty recurrent bind/evaluate/commit and snapshot, one full + one sliding kind, short request ring capacity, pre-wrap and post-wrap frontiers, cancellation after partial native evaluation, failed output validation and retirement. Confirm rows are unbound, backend live/reserved bytes zero and native errors remain primary. No speculative post-wrap rollback or Gemma MTP is admitted by these ordinary-generation tests.

For full global30 policy preservation without production weights, use pure predicate tests rather than allocating fake production experts. Later actual registered execution must capture existing native dispatch counters where appropriate: metadata eligibility is distinct from real R1 hits and NAX precedence. A final narrowed row may intentionally fall below assignment thresholds.

## Registered payload and physical qualification (not run)

Root must verify the selected actual payloads against the declared manifest and validate authentic constructed inventory before loading. The standalone selected-load entry should prove per-rank parameter count, source/destination conservation, exact independent compact storage, replica/source identity, no excluded vision reads, resource bounds, native error handling and canonical journal cleanup.

Then a short shared prompt packet should drive ordinary whole-model reference and two-stage generation with identical tokenizer IDs, profile, cut, quantization policy, prefill schedule, sampling and EOS policy. Compare logits/tokens and all90 globally joined state entries with window-aware descriptors. Only after actual numerical and lifecycle qualification should an installed capability expose Gemma. Long-prompt performance and cut selection require separate measured experiments; no such result is implied by this package.
