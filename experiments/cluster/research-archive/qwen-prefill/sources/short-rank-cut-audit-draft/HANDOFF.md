# Prospective short 12+20 two-rank CPU oracle

This is a separate variant of the frozen serialized rank oracle. No historical
helper or receipt was changed. It is frozen before any native 12+20 rank candidate
access; its numerical reference is the already completed one-process 12+20 run.
The synthetic rank fixtures do not establish native rank correctness.

`qwen_layer_stage_rank_cut12_audit.validate_reports(rank_rows, reference_rows,
epoch, expected, old_sha=...)` is the in-memory checker. Callers using it directly
must establish the raw reference pin; passing a string is not a provenance proof.
Prefer the bounded adapter:

```python
audit_rank_cut12.validate(
    [rank0_stdout, rank1_stdout], reference_stdout, epoch,
    actual_prompt_file, actual_teacher_file, expected_path=None)
```

```sh
python3 -B audit_rank_cut12.py \
  --rank0 COMPLETE_RANK0_STDOUT --rank1 COMPLETE_RANK1_STDOUT \
  --reference COMPLETE_ONE_PROCESS_CUT12_REFERENCE \
  --epoch FRESH_LOWERCASE_HEX32 \
  --prompt ACTUAL_RETRIEVED_PROMPT --teacher ACTUAL_RETRIEVED_TEACHER
```

Use Python 3.10 or later because the preserved comparison helper contains modern
type annotations. Each stdout is bounded at 32 MiB and exactly two complete JSON
records, with the original duplicate-key/depth/type checks and signed-zero parser.
The two candidate paths, reference, prompt, teacher and expected inventory must
be distinct regular files. The adapter pins the raw reference, expected inventory,
raw prompt and teacher, both runtime helpers, and checks all file bytes again after
replay. The existing parent launcher remains responsible for binding both ranks'
actual files to this common input history and for native/source/resource/process
provenance. No source artifact or model payload is loaded by this oracle.

`rank-oracle-cut12.diff` and `mechanical-substitutions.json` describe nine literal
substitutions, including the docstring: a new reference pin, delegated comparison
helper pin/path, expected inventory pin, explicit 0..<12 and 12..<32 ownership,
and 27/45 state-component counts. Eleven whole functions have identical ASTs.
The entire `validate_reports` function differs only at its four range/count
sites; header, ACK, request, state, logit, memory and schema code stays unchanged.
The comparison helper independently binds the full plan, both stage/configuration
fingerprints, all 927 source descriptors and byte accounting to the prospective
12+20 expected metadata. Old 16+16 identities are not silently relabeled.

The checker validates both ready/report identities; fresh request UUID and full
65/32/4 history; six frame/ACK completions; exact previous stage-load receipts;
27+45 state components at frontiers 32/64/65/66/67/68; and the complete 72-entry
state union. It reconstructs the four candidate rank-one BF16 rows and compares
their full native bytes against the qualified baseline, preserving signed zero.
The delegated baseline audit also reconstructs its eight exported comparison
rows. Each complete row has 248320 vocabulary entries.

Boundary payload SHA values are compared between the two ranks and included in
independently reconstructed v1 headers and expected ACK-byte hashes. Raw boundary
and ACK bytes are not exported. A coherent replacement of both payload digests
and their headers therefore remains an explicit, tested observational limit.
Likewise, raw state tensors are opaque: source-derived metadata and recorded
digests/fingerprints are checked, not native state values recomputed on the CPU.
Retirement, model release and completed ACK phases remain source-bound native
assertions. This oracle establishes no physical Thunderbolt/RDMA, timing,
throughput, operator, other-cut or other-model qualification.

Fifty CPU tests pass. They construct rank-shaped records from the authorized
one-process reference, with invented boundary hashes and allocator counters.
Tests cover coherent token/teacher/source/state/logit tampering; wrong stage
construction and plan; layer 12 moved to the wrong owner while recomputing stage
digests; stale 16+16 ranges/reference; parser/input/epoch/retirement/ACK failures;
and the complete bounded file adapter. The original mutation helpers are copied
unchanged. The first prospective run's log is retained: one memory-peak mutation
was a no-op because fake active bytes were zero. Changing that invented count to
one makes peak zero invalid. The runtime oracle was unchanged.

Root commands (CPU only):

```sh
python3 -B check_source.py
python3 -B -m unittest -q test_rank_cut12.py
```

Pipeline's independent source-only review found no blocker in the exact delta,
native DTO correspondence or adapter. It did not run the tests or read any future
rank candidate. The frozen manifest binds this review separately from execution.
