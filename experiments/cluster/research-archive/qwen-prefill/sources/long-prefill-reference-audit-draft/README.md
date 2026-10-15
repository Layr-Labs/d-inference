# Registered 9B 8K reference CPU audit

The validator accepts only the registered BF16 `long_prefill_8k_v1` reference with 8192 prompt tokens, chunk size 512, output count 1, no teacher tokens, and 16 committed chunks. It reads metadata/source controls and caller-supplied prompt/output bytes; it never loads a model or executes MLX.

```python
summary = check_reference(evidence, prompt_data, expected_prompt_sha256)
summary = validate_reports([ready, report], prompt_data, expected_prompt_sha256)
summary = validate(stdout_path, prompt_path, expected_prompt_sha256)
```

Use `parse_rows(raw_stdout)` to preserve Swift's integer spelling `-0` as floating negative zero. The path API verifies frozen dependencies and its input bytes before and after validation. The nested API performs schema/numerical checks; its caller must bind the helper and external provenance. The exact raw prompt SHA is supplied independently by the caller. A self-reported output prompt hash is never accepted as the trust anchor.

`reference_fixture.make_fixture(oracle_module, generated_prompt_bytes)` returns synthetic ready/report dictionaries and performs no I/O at module import. Its factory invokes the oracle's pinned metadata context; no candidate or natural prompt file is read. The test module separately uses the authorized, frozen natural prompt. Synthetic logits include signed zero and a tied maximum, and opaque state digests are marked synthetic in their derivation.

The CPU audit reconstructs all 496,640 bytes of the exported BF16 final row, checks its native-byte SHA, and derives the finite maximum, lowest-index argmax, and tie count. It independently derives all 72 final state entry shapes/dtypes/bytes and the combined fingerprint at frontier 8192, including eight reconstructible Int32 offset digests. The other 64 state component digests expose no raw values. Tests intentionally demonstrate that a coherently replaced opaque digest cannot be rejected without independent native evidence.

The retained source tensor count is 927, distinct from 1,291 raw header entries including excluded vision/MTP. Source layout and byte accounting are recomputed from the frozen canonical inventory. Stage construction identities are bound to the separately frozen pure Foundation plan-control receipt; Python does not guess Foundation's configuration float serialization. Arithmetic/resource receipt fingerprints, request/history/prompt identities, all commits, exact schemas, and capture/retirement scope flags are checked independently. Actual source loading, commits, selection, resource/environment application, retirement, and model release still require the separately archived native executable/source/runtime provenance.

The two allocator observations describe MLX and do not establish process RSS, a whole-process memory bound, timing, physical transfer, workload representativeness, or speedup. No intermediate numerical state capture is asserted.

Run the CPU tests:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/long-prefill-reference-audit-draft/test_qwen_long_prefill_reference_audit.py
```

The freeze records that no candidate output was accessed before freezing this helper/tests. Root began the independent native execution while the prospective oracle was being finished; this is **not** a claim of freeze before native execution. The 51 tests use only synthetic numerical records, metadata controls, and the already authorized prompt input. No native inference, GPU work, SSH, model payload reads, or new process inspection was performed by this audit.
