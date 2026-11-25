# Prospective long-prefill pair CPU validator

Frozen before first candidate-output access on 2026-09-14. This is an external
CPU audit for the registered Qwen3.5-9B, 8192-token prompt, chunk size 512,
one-output, one-process full-width stage comparison. It does not launch native
code or load model payloads. The fixture uses a generated integer prompt and
synthetic state/payload hashes; no actual prompt or candidate was read in tests.

The root may run:

```sh
python3 qwen_long_prefill_pair_audit.py PAIR_STDOUT_JSONL PROMPT_JSON PROMPT_SHA256 \
  --reference-oracle ../long-prefill-reference-audit-draft/qwen_long_prefill_reference_audit.py \
  --expected-reference-oracle-sha256 e316c559f2827c539bd25f0c6baed226e21bc704df3e4facf0d889605914abd1 \
  > pair-cpu-audit.json
```

Run from this directory, or supply absolute paths. `validate(a, stdout_path,
prompt_path, prompt_sha256)` is the file API; `check_pair(a, rows, prompt_bytes,
prompt_sha256)` accepts already parsed values. The file API uses bounded reads
(16 MiB stdout, inherited 64 KiB prompt), strict duplicate-key parsing, exactly
two nonempty JSONL records, and pre/post input/dependency checks. The CLI pins
the reference helper before import and rechecks its bytes afterward. Preserve
the source-review manifest and all helper hashes with the result; the CLI does
not itself attest to native binary or launcher provenance.

`pair_storage.py` closes receipt schemas and reuses the frozen 927-tensor
full-width inventory oracle. `pair_wire.py` independently reconstructs all 16
canonical inner-v2/outer-v4 headers, their separate raw hashes and domain
fingerprints, and the 32 actual-commit metadata records. `pair_final.py` checks
the disjoint 36+36 final state namespace, exact union, source/identity-bound
final digests, final vocabulary metadata/SHA, and native selected token against
the separately validated full reference. Source, common storage, stage-specific
construction/plan identities, profile, prompt, arithmetic-environment commitment,
five allocator observations, and native retirement assertions are also bound.

The nested reference helper reconstructs its exported BF16 vocabulary row and
first-index argmax. The staged candidate exports only logit metadata and SHA:
this audit does not claim direct candidate-byte comparison, candidate tie-count
measurement, an independent model forward, or model-quality qualification.
The 64 numerical recurrent/KV state payloads, residual payload digests, and source
tensor manifest remain opaque commitments. State geometry, eight position-offset
digests, loader inventories, byte conservation, canonical envelopes and all
reported cross-record equality are independently checked. Model execution,
early environment admission, owned native copies and weak-model release remain
source-bound native assertions requiring separate execution provenance.

This local comparison contains no transport completion or post-stop timing
proof. Final digest flags retaining an external post-stop obligation do not turn
this one-process path into a wire/timing experiment. The result cannot qualify
physical transfer, throughput, scheduler performance, or a speedup.

Validation: 13 focused CPU test methods passed in the frozen log. They include
coherently rehashed bad geometry, environment/policy changes, wrong stage
ownership/frontiers, changed state/logit digests, a tied-but-wrong argmax index,
retirement/capability lies, raw/domain hash confusion, allocator inconsistencies,
duplicate/escaped JSON keys, signed-zero preservation and bounded file reads.
The complete positive fixture also checks the published independent v4 hash
vector. No native process or socket is permitted by the validator test wrapper.
The separate baseline helper's 51 tests were not rerun or counted here.
