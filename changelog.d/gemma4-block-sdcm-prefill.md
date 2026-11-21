### Gemma 4 Block-SDCM prefill and paged last-query prefill

- Added `CBv2LastQueryPrefillLayerCache` conformance to `PagedLayerCache`, enabling exact layer-29 last-query prefill on paged Gemma 4 26B deployments (matching the contiguous backend).
- Added opt-in Block-Atomic Causal-Adjoint Multigrid (`Block-SDCM`) prefill (`DARKBLOOM_GEMMA4_PREFILL_SDCM=lightcone|balanced|fast`, default `off`) for solo cold Gemma 4 26B text prompts above `1536` tokens, with exact original-position RoPE, chunked banded sliding-window attention, decoupled `positionDelta` logical KV offsets across paged/contiguous/standalone caches, and safety vetoes excluding compacted sequences from prefix-cache donation and speculative MTP rounds.
- Recorded optional `prefillSDCMMode` provenance in `SchedulerPrefillBenchmarkReport` when Block-SDCM is active.
- Limitation: Block-SDCM is opt-in (default `off`), applies only to solo cold text prefills on non-KV-shared Gemma 4 MoE topologies, and disables durable prefix-cache donation for compacted requests.
