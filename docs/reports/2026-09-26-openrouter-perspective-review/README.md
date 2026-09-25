# OpenRouter-perspective review — 108-issue parity backlog

> Last updated: 2026-09-25 · commit `b6f9574ed`

A dated, frozen review of the Darkbloom codebase (`d-inference`) from the
perspective of OpenRouter's public feature set, filed as 108 dedicated issues
in the DiCompute feature-gap format (`What / Why / Prompt / Workflow / Loop /
Graph / Layout / Flow` plus a `Severity: … · Effort: …` trailer). Each issue is
one file under `issues/`; this page is the index.

## Method

- **Baseline.** OpenRouter's feature inventory was compiled from its public
  docs (`openrouter.ai/docs/*`, API reference, limits, provider-routing,
  rankings and status pages) as of 2026-09-26. Items that could not be
  verified against an official source are marked `[UNVERIFIED]` in the issues
  that cite them.
- **Our side.** Every `## What` cites the d-inference code it describes
  (`path` plus symbol; no line numbers). Absences were verified by reading the
  routing, billing, API-key, console-ui and telemetry code, not inferred from
  missing routes.
- **Process compared.** "Our process" is the DiCompute audit/issue process:
  machine-set `Severity: … · Effort: …` trailer as source of truth,
  verify-before-filing discipline (read the code, check prior art, refuse
  unverifiable categories), one concern per issue, closure-with-evidence. The
  process gaps worth importing into this repo are themselves issues
  ORP-100…ORP-108.
- **Framing.** Darkbloom today is an OpenRouter *upstream provider* — it
  publishes `GET /v1/models/openrouter` (`coordinator/api/openrouter_endpoint.go`,
  `handleListModelsOpenRouter`) and mirrors OpenRouter's uptime formula
  (`coordinator/api/openrouter_uptime.go`). This review asks the inverse
  question: what would it take for Darkbloom's *own consumer surface* to match
  OpenRouter's consumer surface.
- **Not GitHub issues yet.** These are review findings in repo-record form.
  Promoting a row means: sanity-check its citations against current code,
  then file it as a GitHub issue with the same body. Filing 108 live issues
  upstream is a maintainer decision, deliberately not done by this PR.

## Comparison summary

| Area | OpenRouter | Darkbloom today | Issues |
|---|---|---|---|
| Consumer routing control | `provider.order/only/ignore/sort/quantizations/max_price`, `allow_fallbacks`, `require_parameters`, `models[]` fallback lists | Fixed internal cost function (`coordinator/registry/scheduler.go`, `buildCandidateInto`); consumer `provider_serial(s)` stripped (`coordinator/api/request_introspection.go`); self-route only (`coordinator/api/self_route.go`) | ORP-001…018 |
| Error semantics | Typed `error.metadata.error_type`, `provider_code`, `remedy_hint`, mid-stream `finish_reason:"error"`, generation IDs | Closed-vocabulary sanitization (`coordinator/api/inference_error_sanitize.go`), in-band SSE error events, `X-Request-ID` | ORP-019…027 |
| Usage & credits APIs | `/credits`, `/generation?id=`, key CRUD with limits, export | `/v1/payments/balance`, `/v1/payments/usage` capped at 100 (`coordinator/payments/payments.go`, `usageHistoryLimit`), full key CRUD (`coordinator/api/apikey_handlers.go`) | ORP-028…036 |
| Public stats & transparency | Per-endpoint latency/throughput/`uptime_last_30m`, rankings, status page | `/v1/stats` aggregates + instantaneous `decode_tps` (`coordinator/api/stats.go`), `/v1/models/capacity` (`coordinator/registry/model_capacity.go`), provider leaderboard | ORP-037…045 |
| Rate limiting | Credit-based 402s, free-tier RPM/RPD caps, `Retry-After`, limit metadata | Per-account RPM + ITPM/OTPM + per-key overrides (`coordinator/ratelimit/`), early 429 with `Retry-After` | ORP-046…054 |
| Keys, provisioning, orgs | Management/provisioning keys, PKCE auth, workspaces, guardrails | Privy-JWT-only key creation, RFC 8628 device codes, per-key caps/allowlists, no orgs | ORP-055…063 |
| Console UI | Activity feed with per-generation detail, per-key analytics, export, notifications | Billing usage table (last 100), keys manager, stats dashboard, no export/detail views | ORP-064…072 |
| Model catalog | Rich `/models` fields, per-model `/endpoints`, deprecation policy | OpenRouter-provider-schema `/v1/models` (`coordinator/api/models_endpoints.go`), `deprecation_date` field exists | ORP-073…081 |
| Platform features | Transforms, plugins (web, file-parser, healing), reasoning normalization | Tool calling, vision, structured-output support varies per model; no plugin layer | ORP-082…090 |
| Money path | Auto top-up, refunds, fee transparency | Prepaid µUSD ledger, Stripe deposits + Connect payouts, referrals, documented deposit-webhook dedup gap (`docs/architecture/billing.md`) | ORP-091…099 |
| Engineering process | OpenAPI spec + auto changelog, `llms.txt` docs | Strong CI/docs hygiene (docs-check, signed commits, before/after diagrams); no published spec | ORP-100…108 |

## Issues

Severity and effort use the DiCompute trailer vocabulary: severity
`critical|high|medium|low` (blast radius), effort `S` (hours) / `M` (a day or
two) / `L` (multi-day or design-first).

### A. Consumer routing controls (ORP-001…009)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-001 | [Consumer-specified provider order](issues/ORP-001-provider-order-preference.md) | medium · M |
| ORP-002 | [`allow_fallbacks` opt-out](issues/ORP-002-allow-fallbacks-toggle.md) | low · S |
| ORP-003 | [`provider.sort=price`](issues/ORP-003-sort-by-price.md) | medium · M |
| ORP-004 | [`provider.sort=throughput`](issues/ORP-004-sort-by-throughput.md) | medium · M |
| ORP-005 | [`provider.sort=latency`](issues/ORP-005-sort-by-latency.md) | low · S |
| ORP-006 | [`require_parameters` hard gate](issues/ORP-006-require-parameters.md) | medium · M |
| ORP-007 | [`max_price` hard filter](issues/ORP-007-max-price-filter.md) | medium · M |
| ORP-008 | [Quantization-aware model selection](issues/ORP-008-quantization-filter.md) | medium · M |
| ORP-009 | [Request-level `models[]` fallback list](issues/ORP-009-models-fallback-list.md) | medium · M |

### B. Model variants and smart routers (ORP-010…018)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-010 | [Throughput-first model variant (`:nitro` analogue)](issues/ORP-010-throughput-variant.md) | low · M |
| ORP-011 | [Cheapest-first model variant (`:floor` analogue)](issues/ORP-011-floor-variant.md) | low · M |
| ORP-012 | [Tool-calling-quality variant (`:exacto` analogue)](issues/ORP-012-exacto-variant.md) | low · L |
| ORP-013 | [Free-tier router model](issues/ORP-013-free-router.md) | medium · M |
| ORP-014 | [`auto` smart-router model](issues/ORP-014-auto-router.md) | low · L |
| ORP-015 | [Variant resolution and 404 semantics](issues/ORP-015-variant-resolution-semantics.md) | low · S |
| ORP-016 | [Percentile-based soft preferences (`preferred_min_throughput` / `preferred_max_latency`)](issues/ORP-016-percentile-soft-preferences.md) | medium · M |
| ORP-017 | [Consumer data-collection / privacy routing preference](issues/ORP-017-data-collection-preference.md) | medium · M |
| ORP-018 | [Privacy-preserving provider-class `only`/`ignore`](issues/ORP-018-only-ignore-provider-classes.md) | medium · M |

### C. Error semantics and metadata (ORP-019…027)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-019 | [Stable typed `error.metadata.error_type` across all three API skins](issues/ORP-019-typed-error-metadata.md) | medium · M |
| ORP-020 | [Bounded provider-error metadata passthrough](issues/ORP-020-provider-error-metadata.md) | medium · M |
| ORP-021 | [Non-streaming error-body convention parity](issues/ORP-021-nonstream-error-body-convention.md) | low · S |
| ORP-022 | [`finish_reason:"error"` on terminal SSE chunks](issues/ORP-022-stream-finish-reason-error.md) | medium · S |
| ORP-023 | [Queryable generation IDs on every response](issues/ORP-023-generation-ids.md) | medium · M |
| ORP-024 | [`metadata.remedy_hint` on 402/429](issues/ORP-024-remedy-hint-metadata.md) | low · S |
| ORP-025 | [`metadata.limit_source` on 402](issues/ORP-025-limit-source-metadata.md) | low · S |
| ORP-026 | [Opt-in sanitized dispatch trace](issues/ORP-026-debug-dispatch-trace.md) | low · M |
| ORP-027 | [Moderation/policy error taxonomy reservation](issues/ORP-027-moderation-error-taxonomy.md) | low · S |

### D. Usage and credits APIs (ORP-028…036)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-028 | [`GET /v1/credits` (granted vs used)](issues/ORP-028-credits-endpoint.md) | medium · S |
| ORP-029 | [`GET /v1/generation?id=` per-request lookup](issues/ORP-029-generation-lookup.md) | medium · M |
| ORP-030 | [Usage history pagination](issues/ORP-030-usage-pagination.md) | medium · S |
| ORP-031 | [Usage date-range filters](issues/ORP-031-usage-date-filters.md) | low · S |
| ORP-032 | [Usage export endpoint (CSV/JSON)](issues/ORP-032-usage-export.md) | low · M |
| ORP-033 | [Consumer ledger-history endpoint](issues/ORP-033-consumer-ledger-history.md) | low · S |
| ORP-034 | [Per-key usage history endpoint](issues/ORP-034-per-key-usage-history.md) | medium · M |
| ORP-035 | [In-flight reservation visibility in balance](issues/ORP-035-inflight-reservation-visibility.md) | medium · S |
| ORP-036 | [Cached-token savings reporting](issues/ORP-036-cache-savings-reporting.md) | low · M |

### E. Public stats and transparency (ORP-037…045)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-037 | [Public per-model latency percentiles](issues/ORP-037-model-latency-percentiles.md) | medium · M |
| ORP-038 | [Public per-model uptime metric](issues/ORP-038-model-uptime-metric.md) | medium · M |
| ORP-039 | [Public per-model throughput time series](issues/ORP-039-model-throughput-series.md) | low · M |
| ORP-040 | [Public status page with history](issues/ORP-040-status-page.md) | medium · L |
| ORP-041 | [Model usage rankings](issues/ORP-041-model-rankings.md) | low · M |
| ORP-042 | [App attribution headers and leaderboard](issues/ORP-042-app-attribution.md) | low · M |
| ORP-043 | [Published uptime formula, kept aligned with code](issues/ORP-043-uptime-formula-doc.md) | low · S |
| ORP-044 | [Public benchmark results page](issues/ORP-044-public-benchmarks.md) | low · M |
| ORP-045 | [`/v1/models/capacity` freshness/SLO documentation](issues/ORP-045-capacity-freshness-slo.md) | low · S |

### F. Rate limiting (ORP-046…054)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-046 | [Rate-limit headers on success responses](issues/ORP-046-ratelimit-headers-on-success.md) | low · S |
| ORP-047 | [Free-tier daily request caps surfaced in `/v1/key`](issues/ORP-047-free-tier-daily-caps.md) | medium · M |
| ORP-048 | [`Retry-After` coverage audit on all 429/503 paths](issues/ORP-048-retry-after-audit.md) | medium · S |
| ORP-049 | [Per-IP abuse limiting on unauthenticated endpoints](issues/ORP-049-per-ip-unauth-limiting.md) | medium · M |
| ORP-050 | [Limit-approaching warning headers](issues/ORP-050-limit-approaching-warnings.md) | low · S |
| ORP-051 | [Limits reference doc](issues/ORP-051-limits-reference-doc.md) | low · S |
| ORP-052 | [In-flight budget 402 with `Retry-After`](issues/ORP-052-inflight-budget-402.md) | medium · M |
| ORP-053 | [Account ∩ key limit intersection semantics, documented and tested](issues/ORP-053-limit-intersection-semantics.md) | low · S |
| ORP-054 | [Remaining-budget observability per response](issues/ORP-054-remaining-budget-headers.md) | low · S |

### G. Keys, provisioning, organizations (ORP-055…063)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-055 | [Management/provisioning API keys](issues/ORP-055-provisioning-keys.md) | medium · M |
| ORP-056 | [PKCE OAuth flow for third-party CLIs](issues/ORP-056-pkce-oauth-flow.md) | low · L |
| ORP-057 | [Key-hash deep links into console activity](issues/ORP-057-key-hash-deep-links.md) | low · S |
| ORP-058 | [Per-key provider-class allowlist](issues/ORP-058-per-key-provider-class-allowlist.md) | medium · M |
| ORP-059 | [Organizations/workspaces decision record](issues/ORP-059-org-workspaces-decision.md) | medium · S |
| ORP-060 | [Freeform key metadata/labels](issues/ORP-060-key-metadata-labels.md) | low · S |
| ORP-061 | [Per-key spend/rate anomaly notifications](issues/ORP-061-key-anomaly-notifications.md) | low · M |
| ORP-062 | [Per-key zero-data-retention routing flag](issues/ORP-062-per-key-zdr-flag.md) | medium · M |
| ORP-063 | [Signup trial-credit decision](issues/ORP-063-signup-trial-credit.md) | medium · S |

### H. Console UI (ORP-064…072)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-064 | [Activity feed with per-generation detail](issues/ORP-064-activity-feed.md) | medium · M |
| ORP-065 | [Per-key usage analytics view](issues/ORP-065-per-key-analytics.md) | low · M |
| ORP-066 | [CSV export on the billing page](issues/ORP-066-usage-csv-export.md) | low · S |
| ORP-067 | [Usage date-range picker](issues/ORP-067-usage-date-range-picker.md) | low · S |
| ORP-068 | [Cost per message in chat](issues/ORP-068-chat-cost-per-message.md) | low · S |
| ORP-069 | [Latency/throughput/uptime on model pages](issues/ORP-069-model-perf-stats-ui.md) | medium · M |
| ORP-070 | [Model comparison view](issues/ORP-070-model-comparison-view.md) | low · M |
| ORP-071 | [Notification settings (deprecation alerts)](issues/ORP-071-notification-settings.md) | low · M |
| ORP-072 | [Live request playground in the API console](issues/ORP-072-api-playground.md) | low · M |

### I. Model catalog and lifecycle (ORP-073…081)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-073 | [`supported_parameters` in `/v1/models`](issues/ORP-073-supported-parameters-field.md) | medium · S |
| ORP-074 | [`per_request_limits` in `/v1/models`](issues/ORP-074-per-request-limits-field.md) | low · S |
| ORP-075 | [`default_parameters` in `/v1/models`](issues/ORP-075-default-parameters-field.md) | low · S |
| ORP-076 | [Tokenizer/architecture metadata completeness](issues/ORP-076-architecture-tokenizer-metadata.md) | low · S |
| ORP-077 | [Privacy-preserving per-model endpoints listing](issues/ORP-077-model-endpoints-listing.md) | medium · M |
| ORP-078 | [Model deprecation workflow](issues/ORP-078-model-deprecation-workflow.md) | medium · M |
| ORP-079 | [Model status lifecycle surfaced](issues/ORP-079-model-status-lifecycle.md) | low · S |
| ORP-080 | [Canonical-slug / alias stability guarantees](issues/ORP-080-canonical-slug-stability.md) | low · S |
| ORP-081 | [Account-filtered models view parity](issues/ORP-081-models-user-view.md) | low · S |

### J. Platform features (ORP-082…090)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-082 | [Middle-out context-compression transform](issues/ORP-082-context-compression.md) | medium · M |
| ORP-083 | [Response-healing (JSON repair) plugin](issues/ORP-083-response-healing.md) | low · M |
| ORP-084 | [Structured-outputs strict-mode verification matrix](issues/ORP-084-structured-outputs-matrix.md) | medium · M |
| ORP-085 | [Provider-agnostic web-search plugin](issues/ORP-085-web-search-plugin.md) | low · L |
| ORP-086 | [File-parser / PDF input plugin](issues/ORP-086-file-parser-plugin.md) | low · L |
| ORP-087 | [Unified reasoning-effort normalization](issues/ORP-087-reasoning-effort-normalization.md) | medium · M |
| ORP-088 | [`parallel_tool_calls` semantics tests and docs](issues/ORP-088-parallel-tool-calls-semantics.md) | low · S |
| ORP-089 | [Fine-grained tool-call streaming](issues/ORP-089-fine-grained-tool-streaming.md) | low · M |
| ORP-090 | [Citation annotation convention](issues/ORP-090-citation-annotations.md) | low · S |

### K. Money path (ORP-091…099)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-091 | [Stripe deposit webhook dedup gap](issues/ORP-091-stripe-webhook-dedup.md) | high · S |
| ORP-092 | [Auto top-up](issues/ORP-092-auto-top-up.md) | medium · M |
| ORP-093 | [Deposit fee transparency](issues/ORP-093-deposit-fee-transparency.md) | low · S |
| ORP-094 | [Unused-credit refund policy and flow](issues/ORP-094-refund-flow.md) | medium · M |
| ORP-095 | [Crypto deposit rail: implement or remove](issues/ORP-095-crypto-rail-decision.md) | low · S |
| ORP-096 | [Provider custom-price floor/ceiling validation](issues/ORP-096-provider-price-bounds.md) | medium · S |
| ORP-097 | [Minimum-charge floors surfaced in pricing docs](issues/ORP-097-minimum-charge-doc.md) | low · S |
| ORP-098 | [$20 deposit cap review](issues/ORP-098-deposit-cap-review.md) | low · S |
| ORP-099 | [Referral activation decision while platform fee is 0](issues/ORP-099-referral-activation-decision.md) | low · S |

### L. Engineering process, imported from ours (ORP-100…108)

| ID | Issue | Severity · Effort |
|---|---|---|
| ORP-100 | [Published OpenAPI spec with CI drift test](issues/ORP-100-openapi-spec.md) | medium · L |
| ORP-101 | [`llms.txt` and raw-markdown docs serving](issues/ORP-101-llms-txt-docs.md) | low · M |
| ORP-102 | [Automated API changelog from spec diffs](issues/ORP-102-api-changelog-automation.md) | low · M |
| ORP-103 | [Issue fitness scoreboard and gap ledger](issues/ORP-103-fitness-scoreboard.md) | low · M |
| ORP-104 | [Scheduled audit-loop procedure](issues/ORP-104-audit-loop-doc.md) | low · S |
| ORP-105 | [Issue trailer and triage-board fields](issues/ORP-105-issue-trailer-board.md) | low · S |
| ORP-106 | [Incident-named CI gate registry with parity test](issues/ORP-106-named-ci-gates.md) | low · M |
| ORP-107 | [Design records gain revisit triggers](issues/ORP-107-decision-revisit-triggers.md) | low · S |
| ORP-108 | [Environment/ops hazards committed to git](issues/ORP-108-env-hazards-in-git.md) | low · S |
