# Provider Glossary

> Last updated: 2026-11-07

Canonical terms for provider and native documentation. Platform-specific terms
are defined in the external platform documentation.

| Term | Meaning / owner |
|---|---|
| Provider | The Swift process executing models on an Apple Silicon Mac; [component](architecture/components/provider.md) |
| Only me | How a Mac or pair serves: only its owner, through its local API; Darkbloom never contacts it. Set by `--local`, `darkbloom cluster local`, `[local] mode = "local"`. Older text says "direct mode", "standalone" or "local only"; `StandaloneServer` is the code that serves it; [how a Mac serves](provider/local-first.md) |
| Darkbloom network | How a Mac or pair serves: Darkbloom's requests only, earning, with no local API. Set by `--network`, `[local] mode = "network"`; [how a Mac serves](provider/local-first.md) |
| Both, me first | How a Mac or pair serves: Darkbloom's requests and the local API on one engine; the owner's requests pause Darkbloom until 2 idle minutes pass. Set by `--me-first` (older flag `--local-endpoint`), `[local] mode = "both"`. Older text says "unified", "alongside the network" or "local endpoint"; [how a Mac serves](provider/local-first.md) |
| Local API | The OpenAI-compatible address on the owner's Mac (`http://127.0.0.1:<port>/v1`) and its key, which `darkbloom local` shows; served by Only me and Both, me first. Provider-owned, not the centralized backend; [the local API](provider/direct-mode.md) |
| Local key | The key the local API requires (`dk-local-…`). Not the account API key that `darkbloom route key` saves, and not the login token `darkbloom login` saves |
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
