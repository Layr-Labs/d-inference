# Fixed-cut12 8K rank audit

Prospective, separate CPU variant for two ordered rank stdout files with exactly
the registered 8192/512/1 input, source plan `0..<12` / `12..<32`, and either
`serial_v1` or `prompt_lookahead_one_v1`. All previous helpers and results remain
unchanged. No new pair or rank candidate output was accessed during this draft
or its synthetic tests.

The reference input is the **complete separately qualified cut12 pair stdout**.
The validator checks that pair container with the frozen pair oracle, then reads
its actual first-record `reference` object and applies the complete full-reference
oracle. It never synthesizes the old standalone ready/report container or
relabels an old 16/16 reference. Rank request UUID must differ from the nested
full-reference request UUID.

```sh
python3 -B audit_cut12_ranks.py \
  --rank0 RANK0 --rank1 RANK1 --pair QUALIFIED_PAIR_STDOUT \
  --prompt ACTUAL_RAW_PROMPT --prompt-sha256 EXPECTED_PROMPT_SHA \
  --pair-sha256 EXPECTED_PAIR_SHA \
  --pair-cpu-receipt QUALIFIED_PAIR_CPU_RESULT \
  --pair-cpu-receipt-sha256 EXPECTED_CPU_RESULT_SHA \
  --epoch FRESH_HEX32 --policy serial_v1
```

API:
`validate(paths, pair_path, prompt_path, expected_prompt_sha256, epoch, policy,
expected_pair_sha256, pair_cpu_receipt_path, expected_pair_cpu_receipt_sha256)`.
`paths` means rank0, rank1 in that order. The caller supplies independently
established raw pair-output and saved CPU-result hashes; those arguments avoid
changing a frozen helper when the preceding pair qualification completes.
The receipt must be the complete JSON result of frozen `audit_cut12_pair.py`,
not a launcher or execution-status receipt.

The full saved CPU result is compared with a fresh pair replay and the exact
wrapper/dependency metadata, including Plan, reference fingerprint, inventory,
state/logit/token digests, scopes, input hashes, and frozen helper identities.
Origin input path strings are validated as bounded metadata and never used for
IO: transferred files may legitimately have different local paths. The supplied
pair/receipt hashes remain an external trust boundary. This tool does not prove
that the qualification occurred before a native rank process was launched.

## Preserved checks

The frozen pair oracle manifest is
`0364776383f78e5b1d17cc4969a5785d0e20355ff314e3825030e35fdc4acb9e`.
Its complete 21-file archive and the original long-rank source/wire controls are
hash-checked. The selected pair context also verifies the fixed cut12 metadata
derivation, exact Foundation construction bytes, and the 19-member native cut
proposal. These controls do not attest the new executable or live working tree.

The rank core changes only its reference-container calls and scope label inside
`check_rank_pair`. The production file adapter is separate. `rank_wire.py` and
`rank_trace.py` are copied byte-for-byte. `check_source.py` independently checks
the old file pins, exact function changes, literal reference substitutions and
absence of the legacy fake-container construction.

Each stage load retains exact source/config/storage mapping checks: 348/579
active tensors, 2,032,294,848/3,005,746,752 active bytes and 16,384/8,192 inert bytes.
The 27/45 final state components total 119,980,044/199,966,740 bytes and must exactly
match the fresh reference union of 72 components and 319,946,784 bytes.
Sixteen frames, 32 commits, 204/235 action records, full v4 envelope/token bytes,
raw versus domain hash distinctions, expected ACK material, retirement flags,
and source-derived serial/lookahead frontiers keep their original checks.
The origin-local UInt64 diagnostic timer and exact rate arithmetic stay unchanged.

The API bounds each stdout at 16 MiB, the raw prompt at 65,536 bytes and the CPU
result at 256 KiB. All five inputs must be distinct regular files; JSONL outputs
must end in a newline. Closed schemas, duplicate/finite/signed-zero parsing,
source/helper pins and all input bytes are checked before and after replay.

## Evidence limits

The full reference row is reconstructed as BF16 bytes with signed zero and finite
first-index argmax/tie checks. Candidate rows and 64 non-offset state components
remain digest comparisons; no second numerical model forward is executed here.
Eight offset components are reconstructable. Residual payload bytes, actual ACK
bytes, dispatch, memory, release and retirement remain source-bound assertions
requiring separate executable/archive/runtime evidence. No physical Thunderbolt
transfer, representative throughput, process peak, cross-rank clock alignment,
GPU overlap or speedup is established.

CPU fixtures generate both pair and rank containers, raw synthetic values and
placeholder state/payload digests. Production file tests first execute the frozen
pair CPU adapter on those fake files to produce their receipt. Tests include
coherent stale-half/legacy-container rejection, pair-candidate corruption, changed
origin pins/receipt contents, raw/digest/schema/trace/timing mutations, preserved
opaque-payload limits, and input changes during replay. No baseline pin is patched
to a real unrelated receipt.

```sh
python3 -B check_source.py
python3 -B -m unittest -v test_rank test_cut12
```
