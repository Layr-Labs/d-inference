# Native 27B adapter validation increment

This private overlay connects the pinned Qwen3.8 27B artifact to the **existing shared resident runtime** through an explicit `@_spi(Benchmark)` selection. It does not add an engine, model math, state owner, generation loop or cleanup implementation. No MAIN file, compiler, model payload, GPU or remote host was changed or executed for this handoff. Root/independent review and Swift compilation remain pending. The retained source-only checks passed; they are not a native execution claim.

## Runtime changes

`runtime.patch` maps eight files in `integration.json`. Start from the exact `oldSHA256` inputs; three replacements incorporate the earlier reviewed resource-profile overlay. Its source/state limits remain numerically identical.

- `QwenResidentModelDefinition` selects the exact catalog specification, profile ID, explicit candidate cuts and prefill support. 9B stays cut4/8/12/16 with serial/lookahead. 27B validation is serial only at cut4/8/12/16/32, with the half cut derived from the registered layer count.
- `QwenResidentNativeValidationModel.qwen38TwentySevenB.configuration(...)` creates the ordinary load configuration with a closed internal model selection. The public configuration initializer still selects only 9B. Raw model/config/artifact identity, rank, cut and same-host lifetime are checked before returning; actual raw manifest/config, peers, arithmetic, JACCL, selected source, native allocation and OS checks remain in the same admission/load owner.
- Admission derives the model-specific generation profile, Plan and state ceiling. The unadvertised validation scope joins bilateral load agreement. The original 9B serial/lookahead agreement fields and failure messages stay unchanged.
- Registered metadata admission optionally receives the same closed model definition. Only explicit 27B validation expands planning scope; its fingerprint records the candidate cuts. Default 27B metadata still admits only32/32, and all metadata `runtimeExecutionAuthorized`/payload/provider flags remain false. Every storage, diagnostic and loader Plan rederivation uses the same scoped profile. 9B profile/storage fingerprints remain unchanged.
- Source preparation uses the registered manifest ceiling and matches the admitted model. Request allowance uses the same full-model conservative state plus selected GDN fusion and actual per-array allocation bounds. Only 27B gains the explicit context8320/chunk512 cap; the prior 9B estimator/refusals stay intact.

The shared model constructor, quantization/sanitizer, selected aligned reader, load gate, session, KV/recurrent state, wire frames, target token selection, generation driver, EOS/cancel/retirement and recording SPI are unchanged. `QwenResidentLoading.swift` is absent from the replacement set, so the separately reviewed MTP load overlay has no source overlap. The 27B entry keeps MTP disabled.

## Private worker hookup

The normal worker and `QwenResidentCapabilityMetadata.describe` remain 9B-only. Protocol capability validation, installed configuration, provider eligibility and local M5/NAX policy are unchanged. The new SPI is not an installed capability or a way to advertise the artifact.

For an **isolated qualification build only**, apply `private-worker.patch` after `runtime.patch`. It replaces two source files at the existing worker target paths:

1. `WorkerConfiguration` keeps the strict twelve pairs, optional exact prefill flag and complete bootstrap triple. Its optional typed native selection defaults to nil. The private main selects 27B in code; no command-line switch enables it in the normal product. Exact 27B hashes, serial-only policy and candidate cuts are rechecked by the runtime SPI.
2. `WorkerMain` retains the original alarm, pipe owner, `NativeWorkerRuntime`, `WorkerCoordinator` and shutdown flow. It selects the 27B SPI and requires an owner bootstrap attachment. It has no capability-description command. `clock` and `check-arguments` are bounded by the invoking parent and perform no model load; ordinary generation keeps the native <=300s alarm.

Use the existing authenticated configured owner/remote service and canonical device lease; do not launch a naked native process as a replacement for that owner. The worker accepts the same twelve identity/model/rank/cut/deadline pairs and the same bootstrap triple. Each Mac derives its own local uptime. Pin the new worker and matched metallib/resources before either owner starts. The normal product worker sources and existing standalone runtime stubs need no change.

The existing recording wrapper can be reused with this selection in a later private correctness build: reserve/start/recording all consume the same admission profile. This package's private main uses the ordinary token-only wrapper. It does not yet emit a new full numerical reference or a 27B sidecar comparison.

## Exact artifact and geometry

Local directory: `/Users/developer/DarkbloomDev/models/Qwen3.8-27B`.
Public manifest ID: `EigenLabs/Qwen3.8-27B-4bit-mtp`.
Native model: `registered_qwen38_27b`; profile: `registered_qwen38_27b_greedy_generation_v1`.

- Aggregate `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`.
- Config `4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff`.
- Manifest `d1239a5bc6d26d5ce4bf87f22270e3a703f4942e3d0d779948b4f65410df6dcc`.
- All14 manifest files are present locally at declared sizes:16,320,415,757 B. `payload-availability.json` lists every path/size/declared hash. This source task performed **no new payload rehash**. Root reports prior whole-file verification on September14 and no27B artifact yet on either remote Mac. Transfer the exact14 files plus manifest to both; no WAN download is needed. VerifiedCheckpoint still verifies all manifest payloads, including the inactive vision/MTP members.

The same `qwen3_5` constructor already supports the pinned64-layer, interval4, H5120, MLP17408,24-query/4-KV, head256, linear16-key/48-value-head, dim128, convolution4 geometry. The existing metadata gate retains `output_gate_type=swish`; it describes the already fixed GDN SiLU gate, separate from full-attention sigmoid. No operator change is introduced. BF16 W4/G64 target inventory is1847 tensors/15,132,802,048 B. Largest selected tensor635,699,200 B uses the registered path, not the old512MiB legacy limit.

P8192/C512/O128 gives capacity8320,16 prefill+127 decode frames and final frontier8319 without EOS. The actual maximum named-state vector is1,616,248,896 B; residual payload is5MiB under the unchanged16MiB wire cap. Final full-model state has144 components. The 27B tokenizer differs from9B: new prompt IDs and an independent reference are required.

## Staged checks and next root actions

The 121 source checks in `checks.json` passed: exact preimages, patch application/reversal in a disposable source tree, unchanged dependency/policy pins, retained fixture identity, shell syntax, and independent Python integer replay of all five 27B partitions, fusion totals and the 8320-token state vector. No model payload was read. Recheck these source assertions with `python3 check_source.py` against the exact pinned MAIN inputs.

No Swift command was run; root held compiler work during physical HTTP qualification. `Tests/run.sh` is the small Foundation/CryptoKit fixture: it keeps the prior37/53 metadata and13/26 resource checks, then adds exact9B fingerprint/storage equality, scoped27B cut ownership/phase/refusals and8320 bounds. These counts describe the prior retained suites, not a new run.

```sh
bash /absolute/qwen27b-resident-native-adapter-draft-20260915/Tests/run.sh
```

`native-tests.patch` adds three actual-runtime metadata test methods and two worker-parser methods. In the isolated source snapshot, set `DARKBLOOM_RETAINED_PROFILE_FIXTURE` to this package's pinned `Tests/retained-inputs.json`. Run existing `ResidentFacadeTests` and `WorkerTests` along with `NativeValidationAdmissionTests` and `NativeValidationWorkerTests` using root's existing native26.2 build flags. The new runtime methods verify both ranks/cuts, exact identity/profile/frame schedule, logical state+fusion allowance, crossed hashes, malformed scope, preserved public9B admission and unchanged capability rejection. They do not call load, forward, OS admission or GPU APIs. Worker tests require the private parser replacement.

Then build/pin the existing worker target with the private entry. First run actual selected load and a short fresh-state serial request at a cut admitted by current resources on both Macs. Cut4 is a candidate, not an asserted memory fit. Retain raw resources, source/load commitments and real bilateral/native/journal cleanup. Next extend the existing independent full-model reference admission/loader to this exact artifact; compare actual short prefill/decode before8K, then128 target IDs, final BF16 logit row and144 state components. The old9B long-reference gate is still unchanged and cannot supply27B truth.

Only after those results should root introduce an explicit qualified distributed product policy and advertise27B. This overlay does not alter the protected local M5/NAX route, coordinator eligibility or unqualified throughput. Lookahead and MTP require separate subsequent correctness and memory qualification.
