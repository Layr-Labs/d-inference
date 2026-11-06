# Prospective registered greedy-generation comparison

This is the frozen 9B comparator generalized through an explicit registered model/request scope. It has not read any actual 27B reference or candidate output. All tests use fabricated values; passing them establishes comparator behavior only. The original `generation128-numerical-audit-draft-20260915` and its source manifest `98c5e7fb6dbc9bc8b249391900ce5d9f097e503b8d82eab40983cc4a656e3d9c` remain unchanged.

`recorded_math.py` and `snapshot.py` are exact copies, preserving native BF16 reconstruction, signed zero, finite maximum/tie selection, bounded no-follow file snapshots and identity rechecks. The reference/candidate/state join remains the same algorithm. Default 9B geometry and legacy packet rules are unchanged, including its frozen reference/prompt pins. A test compares the complete canonical legacy result byte-for-byte with the original comparator in a separate Python process.

The new `private_registered_generation_comparison_packet_v1` packet adds pinned `registered_request` and `registered_plan` files. The closed catalog admits the retained 9B cut4 and validation-only 27B cut32. Request geometry is independently bounded by the existing software profile; it is never derived from candidate output. Unknown models, other cuts, MTP, stop IDs, mismatched source/Plan/construction identities and differing expected worker builds are refused. Adding this private comparison scope does not advertise executable product support.

`derive_profiles.py` reproduces the catalog from retained raw configuration/manifest bytes and canonical tensor metadata, the original 9B constants, and actual pure Swift 27B Plan/profile/storage output. It reads no model payload. Layout hashing reproduces the source spelling `name:dtype:shape` and checks the original 9B layout. Per-layer state geometry derives from the exact configuration, including 27B's 48 linear value heads and 10,240 convolution channels. `source-authority.json` pins the inspected shared runtime/reference definitions; these are source provenance, not execution evidence.

For the pinned request `20801ced-ca29-4faf-b71a-9ebbe1886a14`, P32/C16/O128, cut32, empty stops and MTP off, the comparator requires:

- All 128 selected token IDs exactly match the independent reference; both finishes are `length`.
- Capacity is 160, final committed frontier is 159 and completed frames are 129 (two prefill plus 127 consumed decodes).
- Both ranks cover their exact disjoint 32-layer intervals: 72 state entries each, 144 total and 164,364,352 logical state bytes.
- The full final 248,320-value BF16 row reconstructs to exactly 496,640 matching native bytes, including signed zeros and maximum tie behavior.
- All 144 state metadata/digest entries and the reconstructed global state fingerprint match. Sixteen position-offset Int32 values are independently reconstructed; the other 128 state entries remain digest comparisons.

The reference must contain both complete JSONL records and its successful retirement/model-release flags. Candidate sidecars retain the original exact field sets, bilateral retirement, agreement, selected history, resource/capture bounds and no-qualification flags. An admission-only reference, missing final report, partial output, extra/missing state, wrong frontier, wrong row, source substitution or mismatched agreement fails.

The comparator still does not reconstruct intermediate logits, independently observe candidate intermediate frontiers, reconstruct the final token chain, read non-offset state bytes, attest native execution/build provenance, replay resource policy or observe physical cleanup. Those flags remain false. No throughput or external TTFT claim is produced. Reference operational envelopes remain pinned but are not treated as resource attestation by this tool.

Prepare the expected agreement before opening candidate sidecars with `prepare_expected.py`. Supply the actual separately bound epoch, storage commitment and numerical-policy hash; the latter two remain explicit caller provenance, as in the original comparison. Do not copy these expected identities from candidate output. The helper builds all request/model/Plan/profile/build fields from the pinned request, prompt and pure metadata Plan, and writes an exclusive mode-0600 JSON file.

```sh
python3 -B prepare_expected.py \
  --request inputs/request.json --request-sha256 d81435faed6ae00db8251530e96da2d276443a62ffa6a971925075b8ec447401 \
  --plan inputs/recording-metadata.json --plan-sha256 d1828272d22d62bd4573cf0da04aa7797e2b18aa59286bd34916cf77c7b8b9d4 \
  --prompt inputs/prompt.ids.json --prompt-sha256 6d4c8898c3d6f01ddd8c3e712cde5005c647db64937977dd907935146442e81e \
  --epoch ACTUAL_EXPECTED_EPOCH \
  --storage-commitment-sha256 EXPECTED_STORAGE_SHA256 \
  --numerical-policy-sha256 EXPECTED_NUMERICAL_POLICY_SHA256 \
  --output FRESH_EXPECTED_AGREEMENT.json
```

Create a fresh packet with exactly `schema`, `request_id`, `expected_agreement` (the prepared object), and `files`. Its six `files` roles are `prompt`, `reference_stdout`, `rank0_evidence`, `rank1_evidence`, `registered_request`, and `registered_plan`; each has exactly `path` and `sha256`. Pin complete successful raw reference bytes and both actual sidecars after collection. Keep their distinct original files. Packet and all six files are bounded, snapshot-checked and rechecked before writing the result.

```sh
python3 -B audit_generation.py --packet FRESH_PACKET.json --packet-sha256 ACTUAL_PACKET_SHA256 --output FRESH_RESULT.json
```

The registered packet intentionally accepts the caller-pinned new reference rather than the old 9B reference hash. Matching that pin is not an attestation of native provenance; root's independent source/build/physical records remain required. The older legacy packet retains its original hardcoded actual reference pin.

`cpu-1` passed 26 fabricated tests. After explicit metadata geometry replay and expected-agreement preparation were added, `cpu-2` passed all 28 tests in 3.661 seconds under Python 3.14.7; runtime/test source pins remained unchanged during the run. The original 16 tests are unchanged. New tests cover 27B positive structure, partial final prefill chunks, short 9B behavior, model/cut/request bounds, source/Plan substitutions, rank coverage, rehashed wrong offsets, capacity/frontier errors, actual bounded packet snapshots and worker-build mismatch. No Swift compiler, model, GPU or network operation was performed by this comparator work. Independent source review is pending at freeze.

```sh
python3 -B derive_profiles.py
python3 -B -m unittest -v test_audit test_registered
```
