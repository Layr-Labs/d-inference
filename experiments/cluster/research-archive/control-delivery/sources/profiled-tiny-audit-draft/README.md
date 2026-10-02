# Prospective profiled tiny validator and runner tests

2026-09-14. Frozen before reading any output from the new native workload.
All fixtures here are invented CPU records, explicitly separate from native
evidence. No model payload, candidate output, native process, GPU or SSH was
used to prepare or test this validator.

`test_profiled_tiny_runner.py` loads only the root runner's Python definitions
and replaces its process, observation, archive and clock operations with fakes.
Every real subprocess, socket and process-group signal is blocked. Ten tests
cover source/archive refusal, initial free memory, pressure/new swap, parent
deadline, independent cleanup error, final output size, stderr, post-run drift,
cleanup of descendants after leader exit, bounded TERM/KILL, and PGID filtering.
The source pin of the reviewed runner and its pinned archive helper is recorded
in the manifest. These tests do not invoke the runner on this machine.

The root runner's two reviewed failure-path fixes are exercised: its original
owned group is cleaned even after the leader exits, and oversized final output
is recorded without an unbounded read/hash. No remaining concrete blocker was
found in this bounded source review. The runner still requires root-controlled
resource checks, immutable provenance and its independent native alarm.

## CPU oracle

```sh
python3 qwen_profiled_tiny_audit.py /path/to/frozen/stdout.jsonl
```

Python API: `qwen_profiled_tiny_audit.validate(stdout_path) -> dict`.
The file is read only at this explicit entry. It must contain exactly nine
complete bounded JSONL records, with no duplicate keys or nonfinite numbers:

1. Explicit long-profile arithmetic-environment receipt.
2. Float32 loader, failure/retirement lifecycle, 1025/512 parity, 8192/512 parity.
3. BF16 loader, failure/retirement lifecycle, 1025/512 parity, 8192/512 parity.

The loader helper copies/adapts the relevant pure checks from the pinned old
`validate-qwen-layer-stage.py`; it never imports that script's native-launcher
support modules. It checks 237 source tensors, disjoint active inventories of
118/119 entries, native tensor shape/dtype/byte conservation, both corruption
rejections, inert-byte accounting, common storage fingerprint and source links.
Native ownership checks remain explicit native assertions, not CPU inspection
of resident buffers.

`profiled_tiny_expected.py` reconstructs source configuration from the pinned
synthetic configuration and explicit profile fixture changes. This binds
`max_position_embeddings=8193`, the profile marker, eight layers, interval four,
full model widths and the flat Float32/wrapped BF16 difference through exact
configuration SHA. It does not predict random model weights or artifact hashes;
those are linked across the verified loader and parity records.

Every prompt token, profile/request fingerprint, six distinct request UUIDs,
prefill-only step and final frontier is checked independently. The two timeline
lengths are 3 and 16 frames, with 18 state components at every frame. Source
geometry gives exact full-state byte totals:

- Float32: `841728 + 2048 * committedTokens + 8`.
- BF16: `814080 + 1024 * committedTokens + 8`.

These totals include six native conv states, six Float32 recurrent matrices,
two native attention key/value pairs and two Int32 offsets. They are logical
state bytes, not process allocation or RSS estimates. The raw state equality
is asserted by the native same-chunk comparison; only its geometry and digest
form are visible to this CPU oracle.

All four final logit rows must export all 512 finite values in the expected
native dtype. Their logical byte SHA is reproduced independently from those
values. The selected baseline/stage token must equal the first maximum index,
including ties; the pinned Metal `ArgMax.reduce` explicitly selects the lower
index on equality. No token is copied from an earlier short-prompt experiment.

## Prospective checks

```sh
python3 -m unittest -v test_profiled_tiny_runner.py test_profiled_tiny_audit.py
```

Twenty-one tests pass using only fake operations and invented records. Oracle
mutations cover wrong environment/profile/context, loader identities/bytes,
record order, retirement, token history, fingerprints, reused UUIDs, state
frontiers/bytes, partial rows, nonfinite logits, wrong selection, duplicate JSON,
partial output and byte limits. Every source/helper used by the oracle is
pinned in the accompanying manifest before any candidate is read.

The resulting audit qualifies only the observed tiny local correctness record.
It does not qualify 9B/27B, a real two-machine link, throughput, overlap,
warmed reuse, memory safety or the eventual 800-TPS target. Runner provenance
and resource receipts remain separate evidence that root must review.
