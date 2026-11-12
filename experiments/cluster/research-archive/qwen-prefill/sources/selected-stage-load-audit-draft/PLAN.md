# Selected-stage loaded metadata audit

This CPU-only audit consumes one complete selected-stage stdout file with an
explicit raw SHA-256 pin, expected registered profile and expected stage index.
The native process, parent source/bundle checks and their success status remain
separate evidence. The helper never invokes a native executable, SSH, compiler,
MLX, model loader or tensor-payload reader.

```sh
python3 -B audit_selected_stage.py \
  --stdout /absolute/retained/stdout.jsonl \
  --stdout-sha256 ROOT_SUPPLIED_RAW_SHA256 \
  --profile registered_qwen35_9b --stage-index 0 \
  --output /absolute/new/loaded-metadata-audit.json
```

The output must be new. Both audit failure and success produce a mode-600 JSON
receipt. A wrong raw pin, malformed result or metadata mismatch retains a failed
receipt; previous reports and run evidence are never overwritten. The optional
`--retained-metadata` path must still match the exact existing shared fixture pin.

`selected_expected.py` reads only the pinned retained registered JSON metadata.
It reuses the frozen constructor V2's canonical JSON, strict integer decoder,
dtype spellings and sorted layout hash recipe. The frozen parent outer contract
is copied byte-for-byte. No new profile or Plan serializer is introduced.

The auditor independently partitions every canonical source tensor at the
registered default half: layers 0–15 / 16–31 for 9B and 0–31 / 32–63 for 27B.
Embedding belongs to stage 0; final norm and head belong to stage 1; local layer
indices subtract the stage start. It requires complete, ordered, disjoint active
metadata with exact names, shapes, source/loaded dtypes and logical bytes. Only
F16 changes to BF16. In particular, the 24 registered 9B F32 A_log arrays remain
F32, twelve in each stage.

The selected loaded active mapping, its layout digest, full expected source
layout, exact inert placeholder metadata, and both storage summaries are checked
against those derived expectations. The other stage's summary is expected
constructor/storage metadata; it does not claim that the other stage was loaded.
Active mapping and storage commitment hashes use the existing canonical recipes.
Per-tensor allocation bounds must cover logical bytes and their sum must equal
the reported rounded total; the actual allocator rounding function is not
replayed. These scalar checks do not prove process memory safety or peak memory.

Unused head/norm/embedding placeholders have exact BF16 shapes and replacement
responsibilities derived from the pinned Plan/inert source. Their values and
eagerness remain unverified: the stage loader evaluates active arrays individually,
then freezes/introspects the model without evaluating unused placeholders.
No assertion about the values of those sentinels is made by this CPU metadata
comparison.

Plan/profile/requirement fingerprints and construction-config fingerprints are
strict SHA-256 identities whose cross-record consistency is checked, but their
serialization is not independently replayed. Likewise, the source descriptor
offset-manifest digest is an opaque, coherent identity; no safetensors headers or
payload bytes are read by this auditor. The registered raw config/manifest and
canonical inventory pins remain independent inputs.

Success qualifies the reported selected loaded metadata, not tensor values,
forward correctness, numerical parity, provider eligibility, physical fused
buffer lineage, native lifetime, current resource measurements or throughput.
The helper publishes explicit false flags for those unsupported claims. Root
must interpret the audit together with the separately guarded native/parent
evidence and its original status.

The package was drafted after root's selected-stage process began, before any
candidate output was read by the auditor author/reviewer. Tests use fabricated
JSON output with the real retained metadata as expectations. Both model profiles
and both stage indices have fabricated positive records. Mutations cover exact
F32 preservation, cross-stage/local mapping, missing/extra/reordered tensors,
Boolean metadata, inert geometry, re-sealed storage mismatches, hashes, allocator
bookkeeping and retained failures. Passing fabricated records proves neither a
native run nor independent Plan serialization; these limits are also asserted
by the fixtures.
