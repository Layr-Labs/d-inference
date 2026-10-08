# Python dependencies for a selected 8K layer cut

2026-09-14. Source-only map. No helper imports, candidate reads, model reads,
native calls, SSH, or repository writes were performed. `source-pins.json`
records exact inspected source paths, sizes and SHA256 values. All line numbers
below refer to those pinned bytes. Paths are relative to `cluster-research`
unless prefixed `repo:`.

The smallest next execution is a new one-process pair invocation with
`--stage-cut 12`: its normal first checkpoint already produces the complete
full-model reference under the selected plan, releases that model, and then
compares both stages. A separate reference invocation is unnecessary for that
pair check. A later rank audit must admit the newly qualified same-cut reference
with explicit raw-output/CPU-receipt pins; the old standalone half-plan reference
cannot be relabeled. Root owns execution and native integration.

The native proposal is separately owned in
`8k-stage-cut-extension-draft/DEPENDENCIES-v2.md` and
`source-pins-v2.json`: optional cut in long reference/pair/rank only; omission
means exactly16/16; explicit cuts4/8/12/16/20/24/28; long solo stays rejected.
Profile, request, report, v4 wire and numerical semantics stay unchanged. This
map does not expand that scope or implement a launcher.

## Split-dependent seams

| Source and lines | Present coupling | Narrow prospective change |
| --- | --- | --- |
| `remote-long-pair-launcher-draft/long_reference_configuration.py:15–30` | Exact fixed pair argv omits cut; the equality checker regenerates that argv. | New cut12 variant appends exactly one `--stage-cut 12`; the same builder must drive staging and post-run comparison. Preserve native300/parent330 and all existing arguments/environment. |
| `remote-long-pair-launcher-draft/launch_remote_long_pair.py:64–74`; `long_reference_artifacts.py:23–29` | Entry constructs and hashes rank.json; later configuration is regenerated for equality. | Bind the explicit selected cut/ranges in the new receipt and its selected-plan expectation. Keep the same raw config hash in remote controls; controls need no new execution behavior. |
| `remote-long-pair-launcher-draft/long_reference_contract.py:33–83` | First reference checks source artifact/config; final checks the same reference fingerprint, two stage loads and sixteen frames. Plan identities are currently opaque. | Keep the exact two native outer schemas. In the new cut variant, bind baseline source plan, both stage plan/config identities and comparison agreement to the independently pinned selected-plan control. Do not turn this outer check into a numerical pass. |
| `remote-long-rank-launcher-draft/long_rank_configuration.py:30–50`; `long_rank_staging.py:9–16,44–50` | Rank argv has policy, dtype, epoch and raw prompt but no cut. | Add the retained explicit cut to both generated configs and their exact post-run verification. Preserve policy values `serial_v1` / `prompt_lookahead_one_v1`. |
| `remote-long-rank-launcher-draft/long_rank_contract.py:9–26,49–55,71–75` | Six plan/stage/config/storage fields are syntactically valid hashes; peers must agree, but the parent does not independently identify the selected split. | Supply the frozen selected-plan/config expectations to the new variant; bind actual local receipt to the corresponding agreement role. Keep storage as an observed coherent commitment unless independently reconstructed by the separate inventory oracle. |
| `long-prefill-reference-audit-draft/qwen_long_prefill_reference_audit.py:25–32,171–214` | Imports the old recorded helper and half-plan expected/control/proof; requires mapped counts463/464 at198; includes the resulting plan hash in full-reference source at203–205. | A new explicitly selected context binds a prospectively derived cut12 control and expected inventory. Preserve the full-source inventory, geometry/environment/resource derivation and numerical `check_reference` body at284–352. Do not merely copy/change a source plan hash in old evidence. |
| `long-prefill-pair-audit-draft/pair_storage.py:15–36` | Loads the pinned half-plan expectation/control and delegates inventory checking to the old helper. | Select the new pinned expected/control and a source-reviewed cut-aware inventory helper. A constant change in this file alone is insufficient. |
| `qwen_layer_stage_recorded_audit.py:115,126–127,168–191` | Counts463/464; ownership uses `layer // (layers // 2)` and local index uses modulo half. It then compares complete expected arrays and source conservation. | Reuse the already prospective short cut12 base variant or factor only the validated ranges/counts in a new copy. Use `[start,end)` and `global-start`; retain uniqueness, allowed endpoint modules, inert replacement metadata, dtype/layout/hash checks, all927 source descriptors and byte conservation. |
| `long-prefill-pair-audit-draft/pair_final.py:19–45`; `qwen_long_prefill_pair_audit.py:95–98` | Filters `rank*16`, requires36 entries and159973392B per stage; summary repeats those constants. | Derive selected global ownership from12/20 and check exact27/45 component sets and119980044/199966740B. Preserve the disjoint complete72-entry/319946784B union and exact final metadata/digest/token comparison. |
| `long-prefill-rank-audit-draft/rank_dependencies.py:9–24,56–66` | Imports and pins the old reference/pair helpers and original native source manifests; hard-pins old standalone baseline and CPU receipt. | Pin new reviewed selected-cut dependencies and a newly qualified same-cut reference. If the reference comes from a pair checkpoint, use a narrow explicit checkpoint extractor plus its pair-audit receipt; do not pretend the file is the old standalone ready/report format. |
| `long-prefill-rank-audit-draft/qwen_long_prefill_rank_audit.py:52–67,137–155` | Baseline uses `baseline_rows[1]['evidence']`; production validate enforces old raw baseline/receipt pins. | Admit a declared new same-cut reference container and source/plan identity before comparison. Keep baseline and rank UUIDs distinct and preserve raw pin/reread/source checks. |
| `long-pair-provenance-draft/long_reference_provenance_records.py:27–67`; `long-rank-provenance-draft/long_rank_provenance_records.py:44–97` | Exact old namespace and argv omit cut. | New small provenance variants recognize only the new launcher namespace/selected cut and regenerate the exact cut argv. Keep native300/parent330, passed/cleanup/retirement truthfulness and local-client-versus-remote-observation distinction. |
| `long-pair-provenance-draft/long_reference_provenance_archive.py:19–47`; `long-rank-provenance-draft/long_rank_provenance_archive.py:24–57` | Pin a particular old review schema/test count, source inventory and launcher files. | Bind the new prospective source freeze honestly. Do not reuse old test receipts or weaken source drift checks to accept changed launchers. Workload helpers still check exact before/after control/config/raw input hashes. |

## Values that must not move with the cut

| Quantity or mechanism | Unchanged source basis |
| --- | --- |
| 8192 prompt, chunk512, one output, no teacher; sixteen frames, two commits per frame | `remote-long-rank-launcher-draft/long_rank_identity.py:19–37,64–73`; pair/rank wire loops. These16s count request frames, not layers. |
| Profile/request/history hashes for identical UUID/raw history | Plan is not in the request domain; plan belongs in source/agreement. A new actual run still has a fresh UUID/epoch. |
| v4 start/boundary/token/ACK domains, exact raw JSON hashes, payload `[1,512,4096]` BF16 =4194304B | `long-prefill-pair-audit-draft/pair_wire.py:12–63`; `long-prefill-rank-audit-draft/rank_wire.py:22–35,54–80`. They derive plan/stage/config/storage from admitted loads. No codec version change is needed. |
| 204 sender /235 receiver actions,16 original boundary releases, lookahead15 prepared-ahead frames | `long-prefill-rank-audit-draft/rank_trace.py`; rank audit95–117. Layer redistribution does not change the16-frame protocol schedule. |
| Full32 layers,927 canonical tensors,5038041600 source bytes; final72 state components/319946784B | Reference context178–212 and `state_geometry`155–168. Selected cut changes ownership, not full-source or full-state conservation. Cut12 known active counts348/579 and bytes2032294848/3005746752 must be independently bound to the selected inventory, not inferred solely from counts. |
| Full hidden/head/quantization math, BF16 conversion, query128, TF32=1 | Existing native profile/arithmetic admission and exact launcher environment. No parameter slicing, tolerance change or precision substitution. |
| Final-logit shape BF16[1,248320],496640B; native finite argmax/first tie behavior | Reference oracle reconstructs the complete reference row only. Candidate pair/rank rows remain metadata/SHA-only; no candidate raw-byte or independently recomputed-model claim. |
| Named resource ceiling and process gates | Whole-model named-state/boundary budget remains745345056B/768MiB; source loader6GiB, payload8GiB, largest tensor512MiB unchanged. Preserve initial actual free6GiB before remote bundle/model reads, posthash reclaimable8GiB, pressure<=2 and zero reported swap. Per-stage redistribution does not itself qualify resident memory safety. |

## Execution/provenance preservation

Keep both frozen launcher folders unchanged and create new private variants.
`remote-long-pair-launcher-draft/remote_prefill_paths.py:31–33` constructs
`run/native` and **`run/native/bundle`**. The rank constructor
`remote-long-rank-launcher-draft/long_rank_paths.py:31–33` constructs
**`run/bundle`** and ordered `run/rank-0`, `run/rank-1`. Copy the actual path
constructors; do not infer a shared layout from fixtures.

Retain bounded raw8192 prompt and origin pins, byte-preserving copies,
`input_files={}`, remote before/after raw prompt, model manifest/config and full
artifact verification, immutable bundle/runtime/source archives, exact retrieved
metadata hashes and no model payload copies. Preserve pair empty stderr;
rank stderr permits only its exact archived-source loopback warning. Existing
launcher stdout/line caps are8MiB; no split change warrants increasing them.
The numerical readers' separate16MiB file cap does not enlarge launcher admission.

The pair supervisor already rechecks the parent deadline immediately after
the memory observation (`remote_prefill_supervision.py:24–29`), so no new guard
is needed there. The old rank supervisor lacks that second check; a new rank
variant can copy the narrow already-reviewed short-rank correction before
accepting success. Preserve stop/cancel/reap bounds, primary versus cleanup
errors, remote observed process absence versus local SSH `wait`, and whole-cohort
cleanup. No native process timing becomes a performance qualification.

Public promotion is later: `repo:experiments/cluster/runtime/stage_checks/cli.py:50`
calls short-only `stage_ranges.option` before long dispatch; `long_cli.py:25–42`
has no cut; `long_configuration.py:22–45` omits it. Do not expose the public
short flag to long commands or solo as a side effect. A later native-aligned
public change needs an explicitly scoped retained selection and independent
selected-plan binding; this task changes none of those files.

## Small prospective test set

1. Omitted and explicit16 generate the historical admitted plan, with omitted
   argv/default DTO bytes unchanged. Explicit12 produces one flag pair only;
   reject Boolean/noninteger/duplicate/illegal cuts and reject long solo.
2. Exact fabricated pair checkpoint +stage loads at12/20 pass only with the
   pinned selected control. Reject half-reference/new-stage mixing, swapped
   stages, stale config/plan/storage and a coherently shifted local layer map.
3. Derive source inventory and final state ownership from the complete pinned
   descriptors/geometry. Check27/45 and full72 conservation; reject a boundary
   layer in the wrong stage, duplicate/missing component, changed shape/dtype/
   byte count/hash and stale equal-half summary. Preserve final token/logit checks.
4. Reuse the unchanged strict/signed-zero parser and wire/action negative cases.
   A valid cut changes agreement hashes, not frame count or ACK/action ordering.
5. Fake supervisor expiry inside memory sampling, source/control/raw prompt
   drift, parent/child failure and cleanup error remain failures. Derive the
   path fixture from the actual pinned constructor.

These are proposed checks, not executed qualification. Arithmetic agent
independently confirmed the reference/pair/rank pin seams from source only;
pipeline agent supplied the native scope. Freeze numerical variants before
candidate access and retain every historical source/test/run receipt.
