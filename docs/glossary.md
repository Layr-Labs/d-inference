# Provider Glossary

> Last updated: 2026-10-09

Canonical terms for provider and native documentation. Platform-specific terms
are defined in the external platform documentation.

| Term | Meaning / owner |
|---|---|
| Provider | The Swift process executing models on an Apple Silicon Mac; [component](architecture/components/provider.md) |
| Local API | Provider-owned on-device HTTP service, not the centralized backend; [direct mode](provider/direct-mode.md) |
| Platform | External coordinator/backend, Rust sidecar, consumer console and admin; [ownership](developer/navigation.md) |
| Native runtime | Source-matched MLX host library, kernels and model execution; [dependencies](architecture/components/mlx-swift.md) |
| Full LOAD quotation | Admission footprint including validated transient allocation and safeguards, not steady residency; [memory policy](architecture/hardware-support.md) |
| Activation floor | Measured reserve used for a serving set, not a per-request shape formula; [memory policy](architecture/hardware-support.md) |
| Prefix cache | Reusable request state with exact identity, ownership and retention rules; [cache architecture](architecture/prefix-cache.md) |
| DBK3 | Authenticated encrypted on-disk provider cache format; [SSD reference](reference/ssd-kv-cache.md) |
| Attestation | Evidence about identity/posture, not a computation-correctness or zeroization proof; [trust](architecture/security/provider-trust.md) |
| Public golden vector | Fixed public input and expected output; does not execute the private implementation; [tests](developer/test.md) |
| Qualification | Explicitly scoped execution evidence at exact revisions/artifacts/hardware, separate from compilation and publication; [performance](developer/serving-performance-qualification.md) |
| Publication | Approved artifact upload and external registration, not backend deployment; [operations](operations/README.md) |
