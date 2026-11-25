# Verified dense-Qwen loading checks

> Last updated: 2026-09-14 · commit `e4df336bc`

The full-model and whole-layer loaders share descriptor validation before
materializing checkpoint tensors. The checks preserve the existing one-part,
shape, packed/floating class and byte-budget rules. They also provide a separate
metadata API for [registered 9B/27B profiles](QWEN_DENSE_PROFILE.md); that API is
not connected to registered-model materialization.

[`observedQwenDenseSource`](Sources/ClusterInference/QwenDenseObservedSourceBridge.swift)
projects metadata from the actual `PreparedQwenCheckpoint` and constructor
parameters. Existing loaders call
[`QwenDenseObservedSourceValidation.validateLegacy`](Sources/ClusterInference/QwenDenseObservedSource.swift)
with the selected BF16 conversion policy and diagnostic or layer-stage purpose.
It returns sorted source metadata, byte totals and the expected loaded-layout
hash. Stored Float16 converts to BFloat16 only when that policy is enabled;
other supported dtypes retain their stored type. The payload read, update,
evaluation and native-error checks remain in the existing loaders.

Legacy admission still limits artifact payload to 8 GiB, canonical source
tensors to 6 GiB and a single host tensor to 512 MiB. The existing tensor-partition
storage checker separately retains its 4 GiB per-rank and 8 GiB combined bounds.
Those tensor-partition bounds are not additional whole-layer loader checks.
These limits do not bound every process, workspace or activation allocation.

`validateRegistered(...identity:profile:requirement:plan:)` additionally requires
the exact complete canonical inventory, raw configuration/manifest and artifact
identities, retained source count, loading policy and rebuilt plan/role binding.
[`QwenDenseObservedStageValidation`](Sources/ClusterInference/QwenDenseObservedStage.swift)
checks source-to-local mappings, active and inert metadata and the existing
compact storage summary. A stage requirement accepts only its own stage;
a pair requirement covers both, while a full-model requirement cannot stand in
for a compact-stage requirement. The records reuse the existing receipt types.
Matching supplied metadata does not verify its provenance or authorize loading.
Registered 27B materialization remains unwired, and `runtimeExecutionAuthorized`
remains false. Independent device, payload and resource admission is still required.

`PreparedQwenCheckpoint` and
[`VerifiedCheckpoint`](Sources/ClusterInference/VerifiedCheckpoint.swift) accept
an optional final `expectedManifestSHA256` argument. A supplied lowercase SHA256
pins the exact raw manifest bytes, including whitespace. It enables a 4 MiB
manifest bound and must match before decoding or opening listed payload files.
The constructor still verifies configuration, every file and the aggregate;
`verifiedManifestSHA256` is exposed only after that verification succeeds.
Omitting the argument preserves the existing IO/hash behavior and leaves the
property nil. Existing loader calls omit it; no CLI flag is added.

Run the Foundation fixture on macOS from the repository root:

```sh
bash experiments/cluster/inference/Tests/ObservedDenseLoader/run.sh
```

The runner compiles 30 source files under Swift 6 with warnings as errors. It
uses the shared retained metadata fixture in `Tests/RegisteredDenseProfiles`
and small helpers in `Tests/LayerStageCandidates`, with no duplicate model data,
SwiftPM build, MLX linkage or network access. Temporary compiler output is removed
on exit. An optional first argument selects another reviewed production source
directory.

The standalone fixture passed 22 accepted and 104 rejected cases with empty
stderr. Synthetic constructor observations cover source/layout policy, complete
registered inventory, wrong identities, role replay and coherently changed
compact records. A separate temporary-file check invokes the actual
`VerifiedCheckpoint` constructor with a three-byte config and three-byte payload:
it verifies the aggregate and raw pin, preserves legacy nil behavior, rejects
wrong pins before missing payloads, and still rejects corrupt payloads when the
manifest matches. This is CPU validation of descriptors and checkpoint IO;
it does not qualify 27B loading, model numerics, memory safety or performance.
