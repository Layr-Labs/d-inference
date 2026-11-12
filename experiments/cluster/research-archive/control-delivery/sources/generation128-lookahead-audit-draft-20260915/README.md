# Private prospective lookahead generation comparison

This is a separate lookahead-only derivative of the frozen serial comparator `generation128-numerical-audit-draft-20260915` (manifest `98c5e7fb6dbc9bc8b249391900ce5d9f097e503b8d82eab40983cc4a656e3d9c`). The original remains unchanged. The native schema source is frozen lookahead Runtime manifest `aa91244615528a5534b811d53368cbb6a1b30903dee18d7800027c79a2f391ca`.

The scope remains registered Qwen3.5 9B, cut 4, the same 8192-token prompt, chunk 512, exactly 128 output tokens, empty stop set, MTP off, request `6426b803-8b80-40ba-8944-b0f4b403a3cf`. The retained full-reference/prompt raw hashes remain fixed at `748b2d11346b3097435f83db53296c4873c3e42a261493614cbfe896883faaa3` and `ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997`.

Only two runtime files change. `audit_common.py` now requires the agreement field `prefillSchedulingPolicy` to equal the native enum spelling `oneChunkLookahead`. Its canonical agreement fingerprint therefore includes that field. `audit_candidate.py` requires each execution's `prefillSchedule` to have exactly these six keys and native types:

| Field | Rank 0 | Rank 1 |
| --- | --- | --- |
| `policy` | `oneChunkLookahead` | `oneChunkLookahead` |
| `rank` | 0 | 1 |
| `preparedAheadFrames` | 15 | 0 |
| `maximumPreparedBoundaries` | 1 | 0 |
| `pendingConsumedAtCompletion` | 0 | 0 |
| `decodePrefetchCount` | 0 | 0 |

The 16 prompt frames produce 15 preparations ahead on rank 0; rank 1 has no producer. These reported counters are checked against the closed expected native behavior. They do not independently establish concurrency, per-frame timing, resource usage, or intermediate frontier correctness. Serial/missing/mixed policy records are refused. The private worker environment spelling `one_chunk_lookahead_v1` is deliberately different from the native encoded enum spelling.

All 128 selected IDs, final 143-frame/8319-token frontier, source/Plan/stage identities, final 496,640 BF16 row bytes including signed zero and lowest-index maximum, and the complete ordered 72-entry state union retain the original checks. Eight position-offset digests are reconstructed; the other 64 state digests are compared without their underlying bytes. The final token chain is compared across ranks, not independently reconstructed. Reference intermediate row hashes remain opaque. All missing intermediate-comparison, execution-binding, physical qualification, performance, throughput and external-TTFT flags remain false. All output receipt construction is unchanged; `expectedAgreement` records the required lookahead policy.

The five other runtime helpers and all 16 original test bodies are byte-identical. The invented fixture adds only the two scheduling structures; six additional test methods exercise exact keys/types/counts, absent/raw-env/serial policies, swapped ranks, old serial fingerprints, and preserved evidence limits. All 22 fabricated CPU methods passed under `/usr/bin/python3` (3.9) in 8.181 seconds, with stable source pins; `cpu-1/` retains the invocation and output. No actual candidate sidecar, model, worker, GPU or network was accessed while preparing this revision. The retained full reference was not reread; its validator and fixed pins are unchanged from the original's recorded replay.

Run:

```sh
/usr/bin/python3 -B -m unittest -v test_audit test_lookahead
/usr/bin/python3 -B audit_generation.py --packet /absolute/new-packet.json --packet-sha256 <raw-sha256> --output /absolute/new-result.json
```

The packet envelope is unchanged: exactly `schema`, `request_id`, `expected_agreement`, `files`; schema `private_generation128_comparison_packet_v1`; files exactly `prompt`, `reference_stdout`, `rank0_evidence`, `rank1_evidence`, each with `path` and `sha256`. Snapshot bounds and exclusive result publication are unchanged. The complete expected agreement must be derived from the new native build identities and fresh membership epoch before inspecting the candidate. Its numerical policy/storage commitment remain explicitly caller-supplied identities. No prospective real packet is generated until root supplies those new identities and intended sidecar paths/pins. Do not carry the old serial agreement fingerprint or token-history seed into that packet.
