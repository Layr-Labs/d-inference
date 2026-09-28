# Registered dense-Qwen metadata profiles

> Last updated: 2026-09-14 · commit `e4df336bc`

The pure profile API validates retained metadata for the registered Qwen3.5 9B
and Qwen3.8 27B artifacts. It calculates model, plan and role-specific storage
requirements for 8,192 prompt tokens, chunks of 512 and one output. These values
provide no loader capability or execution permission.

| Metadata profile | Layers | Canonical text tensors | Planning cuts |
| --- | ---: | ---: | --- |
| `registered_qwen35_9b` | 32 | 927 | 4, 8, 12, 16, 20, 24, 28; default 16 |
| `registered_qwen38_27b` | 64 | 1,847 | 32; default 32 |

The closed identities are defined in
[`QwenDenseRegisteredSpecification`](Sources/ClusterInference/QwenDenseRegisteredSpecification.swift).
Model names alone cannot select a profile: admission requires exact raw
configuration and manifest hashes, the expected artifact aggregate and the
complete canonical name/shape/source-dtype/byte inventory. This validates the
supplied metadata; it does not reread checkpoint payloads.

Use [`QwenRegisteredDenseModelProfile`](Sources/ClusterInference/QwenRegisteredDenseModelProfile.swift)
with retained CPU inputs:

```swift
let profile = try QwenRegisteredDenseModelProfile.admit(
    configuration: configuration, manifest: manifest,
    expectedArtifactAggregateSHA256: artifactSHA256,
    canonicalTensors: tensors)
let plan = try profile.makePlanningPlan() // Default halves.
let requirement = try QwenDenseStorageRequirement.derive(
    profile: profile, plan: plan, role: .stage0)
```

`canonicalTensors` contains
[`QwenDenseCanonicalTensor`](Sources/ClusterInference/QwenDenseProfileTypes.swift)
records; input order does not affect identity. `makePlanningPlan(stageCut:)`
uses the existing [candidate and Plan rules](QWEN_LAYER_STAGE_CANDIDATES.md).
Requirement derivation rebuilds that plan and rejects foreign model, stage or
configuration identities, including an unsupported 27B split.

[`QwenDenseStorageRequirement`](Sources/ClusterInference/QwenDenseStorageRequirement.swift)
accepts `fullReference`, `fullSolo`, `sequentialPair`, `stage0` and `stage1` roles.
Each role has a distinct fingerprint. Active and inert weights, the largest host
tensor, GDN fusion replacement allowance, conservative named state budget and
logical final state are separate fields. The partial named-buffer sum is not an
allocator peak or whole-process memory bound. Existing 9B loader caps and
execution admissions remain unchanged.

[`QwenDenseResourcePlanningInput`](Sources/ClusterInference/QwenDenseResourcePlanning.swift)
binds the requirement fingerprint to a caller-supplied policy hash, positive
workspace, allocator/framework, CPU metadata/evidence and OS reserves, and an
explicit total ceiling. `QwenDenseResourcePlan.calculate(requirement:input:)`
uses checked arithmetic and reports whether those amounts fit that ceiling.
It does not authenticate the policy or establish reserve sufficiency: provenance,
current-resource and execution-authorization flags remain false even when the
numbers fit. Actual payload/descriptors, device eligibility and independent
resource admission belong to a future loader capability.

From the repository root on macOS:

```sh
bash experiments/cluster/inference/Tests/RegisteredDenseProfiles/run.sh
```

The runner compiles the actual pure sources with `xcrun swiftc
-warnings-as-errors`, using the small shared
[`TestSupport.swift`](Tests/LayerStageCandidates/TestSupport.swift) helpers.
It feeds the bundled retained metadata fixture to the standalone harness and
removes temporary compiler output on exit. No model download, SwiftPM build,
MLX linkage, GPU initialization or network access is needed. An optional first
argument selects another reviewed production source directory.

The standalone fixture compiled and passed 37 accepted and 53 rejected cases
with empty stderr. It covers unchanged 9B identities/budgets, 27B metadata
vectors, all roles, malformed inventories, plan/role substitution, positive
reserve requirements and integer overflow. This result qualifies the pure
metadata checks; it does not qualify 27B model loading, numerical behavior,
memory safety or performance.
