# Selected cut for the resident physical launcher

Cut8/24 is feasible as a small derivative of the frozen resident V4 launcher. No native cut predicate, wire protocol, arithmetic loop, resource policy, or process ownership change is required by this source map. Preserve the V4 folder and all prior failures. This document does not implement or qualify the derivative.

The smallest next increment is a **fixed cut8 private derivative**, with one pinned selected-source metadata module and three narrow runtime edits. A generic scheduling or model-selection interface is unnecessary for that increment.

## Existing independent metadata

Use `runs/native-prefill-catalog-replay-20260914/nine.catalog.stdout` (SHA `906de56e50cde991a979743fb88b7db6bd8c93306a153a6af1fb761665cb75ee`). Its saved execution records an ordinary Foundation metadata export, seven candidates, no MLX/model/SSH execution. The relevant current Plan, candidate enumerator, and export sources match that saved execution's source pins. The catalog is not a model-run candidate output.

Join its selected `cut == 8` record to the existing pinned registered inventory in `Tests/RegisteredDenseProfiles/retained-inputs.json` (SHA `1a7e2d74df5e055ec31c12478f49d1d07d1bb48cc64d150248859defb518cd25`). The inventory source-name set must exactly equal the catalog's complete, duplicate-free parameter union and names input. Bind the exact raw configuration, raw manifest, aggregate and canonical inventory hashes as the existing selected-stage oracle does. Check every exported global/local mapping independently against the admitted ranges, embedding on stage0, and final norm/head on stage1.

| Metadata | Stage0 | Stage1 |
| --- | ---: | ---: |
| Global layers | `[0,8)` | `[8,32)` |
| Active tensors | 233 | 694 |
| Logical active bytes | 1,545,572,992 | 3,492,468,608 |
| Largest logical tensor | 508,559,360 | 508,559,360 |
| Retained F32 tensors | 6 | 18 |
| Inert tensors / logical bytes | 2 / 16,384 | 1 / 8,192 |
| Final state components | 18 | 54 |
| Final state logical bytes at 8192 | 79,986,696 | 239,960,088 |

Full active conservation stays 927 tensors / 5,038,041,600 logical bytes; final state stays 72 components / 319,946,784 bytes. These are metadata sums, not allocator, RSS, transient, or performance estimates. Moving four layers reduces stage0 logical active bytes by 486,721,856 and increases stage1 by the same amount; it does not establish actual free memory at first request.

Native catalog Plan fingerprint: `0f287a057042275470eeab37596b621d1134061db0c1fd9ef9b09022ea81da92`.

Stage fingerprints and construction hashes are retained verbatim in `metadata-summary.json`. They come from the actual existing Foundation exporter. The adapter must not regenerate Foundation configuration/Plan serialization in Python.

## Narrow changes

Paths below are relative to `resident-physical-integration-v4-20260915` unless stated otherwise. Exact reviewed bytes and anchors are recorded in `source-pins.json`.

| Seam | Current source | Proposed derivative |
| --- | --- | --- |
| Fixed job selection | `physical_common.py:73–88` | Set a single fixed selected-cut constant to 8; use it for both jobs and strict job admission. Preserve serial policy and native300/parent315. The existing closed plan shape can stay unchanged. |
| Native argv | `physical_common.py:162–170` | Replace the literal cut12 with the validated job cut. Require both jobs use the same selected cut before startup. Preserve every other argv/environment/path/bundle field. |
| Source expectation | `rank_validation.py:60–73,81–106` | Replace loading of the prior *qualified cut12 loads* with independently prepared cut8 metadata expectations. Do not call the new expectations previously qualified loads or reuse the cut12 CPU qualification claim. Preserve the actual Ready receipt separately. |
| Final partition | `cut12_pair_final.py:19–24,39–47` | Pass validated selected-stage ranges/component sets to the final checker and slice the unchanged full reference by global layer. Derive component count and logical bytes from that slice, with exact exported component-set and geometry checks. Preserve all fingerprint fields and full disjoint union checks. |
| Small new helper | Existing `selected-stage-load-audit-v2-draft/selected_expected.py:52–114` and catalog | Reuse the pinned metadata/hash recipes, but consume the selected catalog mappings instead of its `layers//2` selection. Produce two expected semantic receipts plus a selection descriptor. No new runtime-controller abstraction. |

The new helper must construct both summaries before accepting either Ready. It checks source/loaded dtype (`F16 -> bfloat16`, F32 and U32 preserved), exact shape/byte count, local-name sorting, active mapping/layout digests, active plus inert layout digest, inert responsibilities and sizes, and complete source conservation. Join native Plan/stage/construction hashes from the catalog to each ordered summary. Assemble the shared storage commitment with these summaries and replay its existing closed canonical JSON digest recipe. Build semantic receipt fields from those expected values, rather than accepting self-consistent values supplied by the new run.

`sourceTensorManifestSHA256` includes file offsets and is cut-independent (`PreparedQwenLayerSource.swift:79–86,110–116`). The bounded inventory fixture does not contain offsets. Retain the existing qualified source-offset manifest pin `cfd388937b0814fe6fa3f4e5a301a109373b69e2ff2ee625bfc4785dc4eef2b3`, bound to the original raw artifact/configuration and pinned `qualified-source-controls.json` plus its CPU audit. Explicitly label this field as carried forward from the qualified source, not newly reconstructed offsets. Do not carry forward old Plan, stage, construction, active mapping/layout, loaded-byte, or storage-commitment hashes. An alternate fresh offset replay would be a separate metadata task, not a reason to read tensor payloads here.

`selected_read_accounting.validated_load` can remain byte-for-byte unchanged: it compares the complete expected semantic receipt, then checks operational counters using the actual selected tensor sizes. Keep the full actual receipt, including accounting, for later `sourceLoadReceiptSHA256`; removing that field from the retained receipt would break the source-bound native hash. `allocator_policy.py` already uses the supplied selected loaded-byte count and can remain unchanged.

## Final-state and wire invariants

The exported stage state maps identify exact global layers and component names. Native `QwenLayerStageProfiledStateDigest.swift:7–61` validates local/global geometry, then publishes the common global-only namespace. A full-model reference can therefore be sliced for cut8 without renaming or synthesizing numerical state.

For each selected range, require the full reference's selected `(globalLayerIndex, component)` set to equal the exported stage set. At 8192 tokens each full-attention layer contributes two BF16 `[1,4,8192,256]` arrays and one int32 `[1]` offset; each GDN layer contributes BF16 `[1,3,8192]` convolution state and F32 `[1,32,128,128]` SSM state. Require exact shapes/dtypes/byte counts, recompute the existing state fingerprint, then compare the complete candidate stage final record. Require concatenated sorted stage entries to equal the full reference entries and have no duplicate global component. Counts alone are insufficient.

Keep `solo_reference.py` and its five original reference pins unchanged. Preserve the independently reconstructed full-reference BF16 row and eight known position offsets. Candidate boundary payload and 64 numerical state components remain opaque digest comparisons; the candidate does not export values. Do not relabel this as independent reconstruction of candidate tensor bytes.

`cut12_rank_wire.py:22–35,54–86,90–118` already derives Plan, stage, construction and shared storage identities from validated loads. Its names can stay historical for this small derivative. Keep exact v4 envelope bytes/domain hashes,16 frame pairs,4096 hidden width,BF16,512-token chunks,ACK recipes,first-token packet,post-stop release and timing checks unchanged. Keep `cut12_rank_trace.py` and `cut12_pair_wire.py` unchanged. The expected token and logits remain those of the same raw8192-prompt full reference; boundary digests are compared across ranks, not against a different cut.

The worker CLI already delegates its explicit cut to `QwenLongPrefillStageCut.resolved` (`native-contract/QwenResidentBenchmarkWorkerCLI.swift:85–88,118`), and current `QwenLongPrefillStageCut.swift:6–28` admits 8 and binds `[0..<8,8..<32]`. No additional native flag or rebuild is inferred from this map; root still owns exact deployed source/binary correlation and any next build/run.

## Verification before a new run

Retain all 20 existing V4 fake tests and their resource/process failures. Add a compact focused set:

1. Pin/catalog/inventory join: cut8 exact 233/694 mappings and complete source conservation; malformed cut, duplicate name, wrong endpoint owner, stale local index, altered F32 dtype or rehashed altered mapping must refuse.
2. Cross-check the same expected-receipt derivation at cut12 against the old pinned qualified semantic receipts byte-for-byte. This is a regression of the metadata recipe, not a new cut12 qualification or a source of cut8 runtime values.
3. Selected binding: cut8 jobs and one argv pair per rank; mixed cuts, old cut12 Plan/config/storage fields, changed source-offset pin, malformed selected-read accounting and nonzero cache metadata refuse.
4. Dynamic final partitions: invented global entries produce disjoint18/54 coverage; boundary-layer ownership errors, duplicated/missing components, reordered or altered metadata/digests, stale27/45 slicing, and wrong final token/logit all refuse. Keep the full72-component union check.
5. Re-run the unchanged four-request/release, missing-peer, bounded stderr, deadline, resource and remote-retirement fake cases against the derivative. No inferred pass from native/SSH exit alone.

Freeze only the small changed files/new helper, their exact inherited dependency pins, selected metadata inputs and focused tests. A deployment package may materialize the already frozen common files, but this extension needs no separately maintained copy of an entire launcher lineage. Root review and actual guarded execution remain separate steps.

## Scope of this map

Performed source inspection, bounded retained metadata reads, SHA checks, exact catalog/inventory name and range joins, and integer metadata sums only. Did not read current physical-run candidates, full-reference numerical files, model payloads or native stdout from those runs. Did not run an exporter, test suite, compiler, native worker, SSH or GPU. No source/launcher implementation changed. The new cut remains unqualified for execution success, physical transfer or throughput.
