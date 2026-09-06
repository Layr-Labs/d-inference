# 0.9.0 paged attention and Qwen caching

> Last updated: 2026-09-06 · commit `2eebb5412`

Status: **In progress** — 2026-09-06 — source activation policy corrected; model acceptance and release validation remain incomplete.

The release migrates five exact artifacts to paged attention. Only the three Qwen artifacts default to SSD prefix caching and belong in the initial cache-routing cohort. Gemma 8-bit (`gemma-4-26b`) remains supported but is outside this release's activation and validation matrix. This supersedes the earlier [Qwen-first paging scope](qwen-first-paged-ssd-rollout.md).

## Activation scope

| Exact model ID | Automatic attention backend | Default SSD cache |
| --- | --- | --- |
| `qwen3.5-35b-a3b` | Paged | On |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | Paged | On |
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | Paged | On |
| `gpt-oss-20b` | Paged | Off |
| `gemma-4-26b-qat-4bit` | Paged | Off |

`EngineV2KVBackendPolicy.preferredBackend` selects the backend independently of `PrefixCachePolicy.isEnabled(modelId:environment:)`. Exact matching avoids enabling aliases or unvalidated quantizations. Explicit backend configuration, capability vetoes, the paging kill switch, automatic failure fallback and the version-bound crash-loop guard retain their existing behavior.

Both SSD codecs use the model-scoped cache gate before constructing stores. Local HTTP and connected serving therefore cannot enable GPT-OSS or Gemma SSD reuse merely by selecting paged. Load-time SSD hashing and benchmark cache expectations use that same model scope. An explicit affirmative `DARKBLOOM_PREFIX_CACHE` remains an opt-in for other models, subject to all existing capability and identity checks; this preserves deliberate offline cache experiments. An unset or empty flag uses the cohort default, and a non-affirmative nonempty flag disables all tiers. Resident retention still requires its separate explicit memory opt-in.

Coordinator routing remains separately gated and defaults off pending activation. Its initial release cohort is the three exact Qwen artifacts with verified aggregate/prompt identities; enabling provider SSD caching does not activate coordinator routing. No production setting, traffic, release registration or package-distribution change is performed by this decision.

## Acceptance work

All five artifacts require cache-off contiguous/paged comparisons at actual B1/B2/B4, repeated and sustained workloads, normal MTP, long contexts and shared-memory pressure. Only Qwen additionally requires SSD output equivalence, authenticated reuse, persistent restart and connected cache routing/fallback checks. Existing failed evidence remains retained.

Qwen 3.5/3.6 backend numerical differences remain open. Gemma QAT's MTP/ordinary-decoding difference occurs on both backends and must be assessed for the shipping configuration. GPT-OSS's SSD-specific B2 failure is outside the initial uncached configuration. Qwen 3.8 has passing initial B1/B2/B4 comparisons, with broader operational and final-runtime evidence still needed. A strict token comparison is a regression signal; relaxing it requires a justified numerical and model-quality acceptance basis.

Signing/package-distribution workflow changes are a separate user-owned task. Release packaging validation must use the accepted source/runtime, but a new signing workflow is not a prerequisite to these inference fixes.

## Rollback

The controls remain independent: `DARKBLOOM_CBV2_PAGED_KV=0` selects contiguous; `DARKBLOOM_PREFIX_CACHE=0` disables local prefix reuse; `EIGENINFERENCE_CACHE_ROUTING_MODE=off` disables routing preference. Paging rollback alone may retain supported contiguous Qwen checkpoint reuse. Production changes require authorization for the specific operation.

Related: [prefix-cache architecture](../architecture/prefix-cache.md), [validation procedures](../developer/test.md), [configuration](../reference/configuration.md).
