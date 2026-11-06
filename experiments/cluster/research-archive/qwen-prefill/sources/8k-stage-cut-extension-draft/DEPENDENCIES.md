# Selectable 8K layer cut: source dependency map

2026-09-14. Read-only source investigation; no new execution qualification.
Paths below are relative to `experiments/cluster/inference/Sources/ClusterInference`
unless prefixed otherwise. Exact inspected bytes are recorded in `source-pins.json`.

| Concern | Existing source | Consequence for a cut-only extension |
| --- | --- | --- |
| Request profile | `QwenLayerStagePrefillProfile.swift:5`, `QwenLayerStageProfiledPrefillRequestSpec.swift:25`, `QwenLayerStageProfiledPrefillRecordedRequest.swift:54` | Profile/request fingerprints bind geometry/history, not the layer plan. Keep the exact8192/512/1 request and existing profile domains. |
| Plan construction | `QwenLongPrefillReferenceAdmission.swift:45` | Currently constructs16/16. An explicit selected plan must be admitted here; default remains identical. |
| Loaded stage admission | `QwenLayerStageProfiledComputeAdmission.swift:17` and `:24` | Two range literals and `loaded.layerCount == 16` are real half locks. Derive from the admitted plan and the loaded stage's index; retain all source, configuration, precision, storage and agreement checks. |
| Legal candidates | `QwenLayerStageCandidates.swift:33` and `:47` | Existing bounded phase-cut enumeration constructs the existing Plan and complete ownership; compute cost remains unknown. This is metadata, not execution admission. |
| Original option scope | `Options.swift:302`; `QwenLongPrefillReferenceCLI`, `QwenLongPrefillRankAdmission`, `QwenLongPrefillPairCLI`, `QwenLongPrefillSoloCLI` | Current original gate rejects every long mode. Reference/pair/rank would need an explicit closed allowance, and solo must reject before its reference clone. Validate mutated Options and bind selected cut to retained plan before IO. |
| Native rank boundary | `QwenLongPrefillRankCheck.swift:9` | Bind selection to `local.plan` before `Collective`, model loading, or request state. Keep the existing source/model cleanup path. |
| Full-reference coupling | `QwenLongPrefillReferenceEvidence.swift:6`, `QwenLongPrefillPairAdmission.swift:15` | Reference source includes `planSHA256`, evidence hashes it, and pair admission requires it. Produce new same-selected-plan reference evidence with unchanged full-model math; never relabel an old half-plan evidence object. |
| Existing wire identity | `QwenLayerStageProfiledPrefillStartAgreement.swift:22`, `QwenLongPrefillRankCheck.swift:74` | v4 already binds whole/stage/construction/storage fingerprints. Changing only the cut needs no wire or profile geometry change. Readiness, headers, tokens and ACKs remain bound to the new actual agreement. |
| Resource admission | `QwenRegistered9BLongPrefillAdmission.swift:30`, `QwenLongPrefillTensorBudget.swift:93` | Uses full registered source geometry, not cut. Preserve exact artifact/configuration/arithmetic/whole-model named-tensor ceiling and live resource gates. Redistribution of resident weights/state is not a new memory-safety proof. |

The native profiled compute/session path already consumes an admitted Plan and
publishes actual source/stage identities. Fixed16 frame counts refer to the
unchanged8192/512 timeline and must not be confused with the half-stage16 layers.
The whole-model32 layers and927 canonical source tensors also remain unchanged.

Independent parent validation needs a new explicit candidate inventory. The
frozen private `long-prefill-pair-audit-draft/pair_storage.py` binds half-plan
metadata; `pair_final.py:20` filters at16 and requires36 components and159973392B
per stage. The rank oracle imports those helpers. Replace only split-dependent
expectations in a prospective variant; preserve full global state/logit/token
checks and the original frozen evidence. New reference identity must be bound to
the new plan even when independently checked final numerics equal the old run.

The public `runtime/stage_checks/long_rank_contract.py` checks agreement/source
hash consistency but leaves inner numerical ownership opaque. A later public
launcher extension must retain selected cut in context, forward it exactly,
bind an independently admitted plan and update outer/fake tests. Existing long
request identity, raw prompt origin, environment, deadlines and resources stay
intact. The short `stage_ranges.py` helper's existence does not authorize8K cuts.

The shortest route to measured split costs is same-cut8K pair correctness,
then a guarded two-rank cohort with the existing optional phase and selected
owner sidecars. Phase spans already cover all16 stage0 `prepare.begin` to
`prepare.committed` intervals and all16 stage1 `receive.beginConsumption` to
`receive.consumptionAndSelectionValidated` intervals. The final consumer span
includes finite token selection. The eight owner markers isolate existing owner
sections at chunk7; they do not add evaluation. Sidecars must be correlated with
the actual source/plan report, because their local identity primarily binds the
request/profile/role. Compare cuts under same-binary, counterbalanced fresh
cohorts with the same workload and resource policy. These are local host spans
including checksum/copy/synchronization/observer costs, not isolated GPU clocks.
Never subtract timestamps across ranks or infer throughput for another model
or machine class from these measurements.

Next proposal scope approved by root: selectable cut for native long reference,
pair and rank only; long solo remains rejected. No implementation, schema,
profile, protocol, numerical tolerance or qualification change is made here.
