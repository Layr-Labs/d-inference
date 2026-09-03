# Prefix cache deep-dive: how it works, why cached routing is dark, and how to turn it on

> Last updated: 2026-08-31 · commit `5d400cf75`

Date: 2026-08-31. Sources: engine/provider/coordinator code at current master,
docs/reports/2026-07-19-frozen-full-prefix-cache-proof.md,
docs/reports/2026-07-26-gemma-26b-adoption-exactness.md,
docs/architecture/cache-aware-routing.md + prompt-contract-sidecar.md,
git history of both repos, and a web survey of vLLM/SGLang/Mooncake/Dynamo/
provider-API caching (late-Aug 2026).

## TL;DR

Everything needed for cached routing **already exists end-to-end** — encrypted
SSD prefix cache on providers, bit-exact adoption, a coordinator prompt-contract
sidecar computing the same block hashes, receipt-verified soft-affinity routing,
canary knobs pre-staged at PERCENT=1/QPS=1. It is dark for exactly one reason
chain:

1. Adoption through the SSD/slot tier is **byte-exact on the paged KV backend
   and silently wrong on contiguous** for both production checkpoints
   (gemma-4-26B QAT diverges at byte 4, gpt-oss-20b diverges; measured six-arm,
   v0.8.0).
2. v0.8.1 reverted the fleet default to **contiguous** — not for exactness but
   for **capacity** (paged eager-slab pool sizing yielded 1,137 GiB fleet KV vs
   11,453 GiB contiguous → 32.7% token_budget_exhausted, TTFT p95 12.8 s,
   OpenRouter uptime ~85%).
3. To close the wrong-answer class, `PrefixCachePolicy.adoptionIsExact` now
   refuses to even **construct** the cache on a resolved-contiguous slot.
4. Net: no default-configured provider builds a cache for any model, so
   flipping the coordinator to `on` would find near-zero protocol-v2 providers.
   The SSD tier was disarmed fleet-wide as collateral of a capacity decision.

Separately, the Qwen hybrids were **never** eligible: recurrent GDN state can't
be rebuilt from attention KV, so `supportsPrefixReuse=false` refuses the cache
regardless of backend. An unmerged branch
(`origin/cursor/qwen-prefix-cache-final-74d1`, 2026-08-24, ~2.6k insertions,
"ship opt-in exact Qwen prefix cache" + coordinator exact-routing tests) already
attacks this; its status is unresolved — evaluate it before writing anything
new.

The enablement path is therefore: **(a)** pick the keystone KV-backend move
(per-model paged flip now, headroom-model fix later, or root-cause the
contiguous divergence), **(b)** canary gpt-oss-20b first (smallest, proven
bit-exact, biggest replay savings), **(c)** Gemma needs the window sidecar
(WS-4.2, already in master) validated to collapse its 26,624-token donation
floor to ~1,536, **(d)** Qwen needs the recurrent-state sidecar — after which
it becomes the *cheapest* adoption in the catalog, not the hardest.

---

## Part 1 — Prefix caching from first principles

**The problem.** A transformer's answer to a prompt is a pure function of the
token sequence. Prefill cost is roughly linear-quadratic in prompt length, and
in multi-turn conversations turn N's prompt is turn N−1's prompt plus a little
more. Everything computed for the shared prefix — the per-layer K/V tensors —
is byte-identical if recomputed. Prefix caching stores those tensors at
donation time and, when a new request's tokens start with a cached prefix,
restores them and prefills only the suffix. TTFT drops from O(full history) to
O(new turn).

**Identity: what makes two prefixes "the same".** Not the chat text — the
*token IDs after the full render pipeline* (template, tool normalization,
endpoint lowering). Both sides hash 256-token blocks into a chain:
`h_i = SHA256(domain ‖ contractID ‖ scopeID ‖ h_{i-1} ‖ i ‖ tokens_i)`.
The chain means a block hash commits to everything before it, so "longest
matched block run" is a prefix match by construction. The `contractID` pins the
tokenizer/template/config artifacts and renderer versions so a coordinator-side
plan and a provider-side proof can only agree if they tokenized identically.
The `scopeID` (HMAC per account + model build + contract) prevents cross-tenant
sharing and cross-tenant timing probes.

**Why exactness is hard — the three layer types.**

- *Full attention* (all of Qwen's attention layers; 5 of gemma-4's 30; half of
  gpt-oss's): K/V at position p never changes once written. Restoring rows
  [0, M) gives bit-exact continuation. Easy.
- *Sliding-window attention* (25 of gemma-4's layers, window 1024; gpt-oss
  alternating window 128): the cache only retains the last W tokens, but the
  *hidden states* that produced downstream full-layer K/V depended on the
  whole history. If you restore full rows and leave sliding rows empty, early
  replayed hidden states differ from the cold run, and those differences are
  *written into* downstream full-layer K/V — they never age out and change
  later logits (the root cause in the 2026-07-19 proof). Two exact solutions:
  **frozen-full replay** — recompute the last R = windows-worth of tokens
  while treating the restored full rows as read-only ("frozen") until the
  boundary M, then flip to normal append (shipped; R = 1,536 for gpt-oss,
  25,600 for gemma-4); or **persist the window too** — the WS-4.2 sidecar
  stores the sliding rows' K/V on disk so nothing needs replaying (shipped in
  master, unproven in the field).
- *Recurrent / linear-attention state* (30 of 40 Qwen 3.5/3.6 layers — Gated
  DeltaNet): there is no per-position K/V. The layer carries a fixed-size
  state that is a function of the *entire* prefix. You cannot rebuild it from
  any stored per-token tensors without replaying every token — i.e. the
  "replay bound" is the whole prefix and caching saves nothing. The only exact
  option is to **snapshot the state itself** at the donation boundary
  (~61 MiB/request for the 35Bs: SSM state + conv tail per layer, fp32) and
  restore it. This is why `supportsPrefixReuse=false` for the Qwen families —
  and why the fix is a state sidecar, not a smarter replay.

**Why adoption must be provably exact here.** Public stacks (vLLM hybrid APC,
LMCache) explicitly accept cold-vs-warm drift on hybrid models (bf16 state
snapshots). We can't: a decentralized network pays untrusted providers per
token, and a cache hit that changes the answer is indistinguishable from a
provider serving degraded output. Our design keeps a "bit-exact or cold"
contract (`PrefixCachePolicy`), and the coordinator quarantines a provider's
cache capability on any hash-proof mismatch. The 2026-07-26 report shows why
this paranoia is earned: contiguous adoption silently returned *truncated,
different* answers on ~1 in 43 flagship requests in the exposed band — a
wrong-answer path, not a latency feature.

**Cached routing = making the cache matter across the fleet.** A cache hit
requires the request to land on the box that holds the bytes. The coordinator
therefore: (1) tokenizes the provider-bound body in its local Rust sidecar and
computes block-hash boundaries (the "plan"); (2) learns who holds what only
from **nonce-bound receipts** providers send after real lookups/donations
(never a block inventory — content-free capability bits in heartbeats);
(3) applies a **soft discount** to the routing cost of a receipt-confirmed
holder — `min(saved_tokens/prefill_tps − stage_ms, 1000 ms, 35% of cost)` —
so a busy holder still loses. No pinning, no KV transfer between providers, at
most 4 holders per boundary, 10-minute holder TTL. This matches where the
industry landed (SGLang router's load-imbalance override; Dynamo's affinity
decay under load; Mooncake's transfer-vs-recompute test — which on our
commodity links always says "recompute").

## Part 2 — Our stack, layer by layer

**Engine (`libs/mlx-swift-lm`, CBv2).** `CBv2PrefixCache` protocol: engine
calls `lookup()` synchronously at admission; adoption machinery
(`makeAdoption → lookup → applyAdoption → endAdoption`) restores per-layer
rows; donation queue hands finished requests' KV out. Frozen-full replay
implements the sliding-window exactness contract; paged and contiguous
backends both reach exact-bound parity in-engine (the divergence lives a tier
up). Per-request salt; quantized-KV donation banned (lossy).

**SSD tier (`provider-swift/Sources/ProviderCore/KVCacheSSD/`).**
`SSDPrefixCache` — the only production implementation:
- *Donation*: chain-hash finished tokens, dedupe, extract only new blocks'
  KV to host buffers (~1–30 ms), write-behind encrypts to per-block `.dbk3`
  files (AES-GCM per-file DEK under SE-rooted KEK, filenames are HMAC tags —
  a disk observer learns nothing). Steady-state resident prefix KV is zero.
- *Adoption*: pre-submit `stage()` probes the index for the longest block run,
  applies a benefit gate, reserves bytes in `GlobalKVCacheBudget`, decrypts
  into a staging map; the engine's lookup finds it there. Every terminal path
  releases the pin.
- *Lifecycle*: 15-minute sliding TTL, 20 GiB box-wide LRU
  (`DARKBLOOM_PREFIX_CACHE_DISK_GB` override), survives restart via directory
  scan, epoch rotation coarsely invalidates on eviction.
- *WS-4.2 window sidecar*: sliding-layer K/V persisted as ordinary DBK3 files
  in a separate HMAC domain, one per 256-token block; adopter assembles the
  window from the blocks tiling [M−W, M) and skips replay entirely; falls
  back to replay if any sidecar is missing. Field-observed only via stats
  counters — never validated under a canary because the tier is dark.
- Threat model: T-041 closed at-rest leaks; SEC-035 (a provider can infer
  from its own TTFT that a prefix was seen before) is an accepted residual.

**Provider protocol.** Provider computes its own contract ID from local
artifacts, advertises `PrefixCacheV2Capability` per model only after SSD scan
readiness, honors the dispatch's `CacheReceiptNonce` + opaque `CacheScope`
(protocol v2 only), emits `prefix_cache_lookup_v2` / `prefix_cache_ready_v2`
receipts with recomputed chain-hash anchors and strictly-increasing sequence
numbers. Proof mismatch → capability quarantined.

**Coordinator (`coordinator/promptcontract` + registry).** Rust
`promptsidecar` (Unix socket, no network) renders + tokenizes the final
provider-bound body and returns `CachePlan{boundaries…}`; `preload_controller`
gates planning until the exact verified contract set is loaded (fail-cold →
`cold_only`, never blocks inference). Templates that call `strftime_now` are
refused (`dynamic_time` → cold-only) because provider Macs render local time.
Scheduler applies the capped discount; TTFT calibration and cold-prefill
reputation exclude cache-participating attempts (the 2026-06-17 contamination
lesson); deadline admission's prefill estimate is discarded on hits. Media
requests are excluded from planning; the engine bridge also gates prefix reuse
to text-only.

**Config surface today.**

| Layer | Knob | Current |
|---|---|---|
| Coordinator | `EIGENINFERENCE_CACHE_ROUTING_MODE` | `off` (since inception, 2026-07-17) |
| Coordinator | `_PERCENT` / `_MAX_PLAN_QPS` | pre-staged `1` / `1` canary values |
| Coordinator | `EIGENINFERENCE_PROMPT_SIDECAR_ENABLED` | `true` in prod (planning infra warm) |
| Coordinator | `EIGENINFERENCE_CACHE_MASTER_KEY` | must be set before `on` (startup fails otherwise) |
| Provider | `DARKBLOOM_PREFIX_CACHE` | unset ⇒ enabled |
| Provider | `engine_v2_kv_backend` (+ `_by_model`) | `auto` ⇒ **contiguous** ⇒ no cache constructed |
| Provider | `DARKBLOOM_CBV2_PAGED_KV` | negative-polarity kill switch only; cannot turn paged on |

## Part 3 — History: what was tried, what failed

| When | What | Outcome |
|---|---|---|
| 2026-05→06 | Prefix cache + SSD tier ported from omlx; encrypted persistence (#32) | Foundation, engine-local |
| 2026-06-16 | Legacy cache contaminated TTFT calibration | Fixed; the exclusion discipline survives today |
| 2026-07-05→09 | CBv2 block-hash cache, per-request salt, quantized-donation ban; v0.7.5 ships SSD tier default-ON | Local (same-box) caching live |
| 2026-07-13 | v1 cache-aware routing (unproven receipts) | Demoted to decode-only a week later |
| 2026-07-17 | v2 exact routing: prompt-contract sidecar, HMAC scopes, proof receipts (#549) | Shipped **dark** (`MODE=off`) |
| 2026-07-19 | Hybrid replay found inexact → frozen-full replay + real-weight bit-exactness proof (lm #78) | Exactness contract established |
| 2026-07-22 | v0.7.12 "provider-first rollout" + telemetry | Explicitly "does not activate routing" |
| 2026-07-26 | v0.8.0 six-arm gate: **contiguous adoption diverges on both prod models; paged exact**. Also: sidecar-restart "did not reopen after re-preload" failed on paged arms; 57k-token staging never published a holder | The two unchased bugs are still open |
| 2026-07-29 | v0.8.1 reverts fleet to contiguous for **capacity** (paged slabs: 1,137 vs 11,453 GiB fleet KV; TTFT p95 12.8 s; uptime ~85%); closes the wrong-answer class by refusing cache construction on contiguous | **SSD tier disarmed fleet-wide; routing never got its canary** |
| 2026-08-24 | Unmerged `cursor/qwen-prefix-cache-final-74d1`: opt-in exact Qwen prefix cache + remote exact-reuse authorization + coordinator exact tests | Status unknown — evaluate before new work |

Rollout doctrine (docs/operations/coordinator-deploy.md): each control raise is
a separate human-reviewed swap; ≥30-min clean window, ≥100 successful plans,
one complete miss→donation→hit lifecycle before raising anything; rollback is
`off` first. The promotion gate has never been executed.

**Stale-doc warning:** docs/architecture/cache-aware-routing.md §rollout still
claims contiguous native-float slots can advertise protocol v2 — that predates
v0.8.1's construction refusal and now overestimates v2 provider supply.

## Part 4 — External landscape (what to copy, what to skip)

- **vLLM APC**: chained block hashes (sha256; `sha256_cbor` for cross-language
  reproducibility — relevant if we ever hash outside Swift/Go), full-blocks
  only, LRU. Hybrid KV manager: SWA groups need only the window tail cached,
  but full-attention groups need *all* prefix tokens, and the hit is the
  intersection — so for SWA+full models **routing signal should track the
  full-attention prefix** (matches our design).
- **Hybrid (Mamba/GDN) caching**: shipped 2026 in vLLM via per-block state
  snapshots at coarse grain (block size inflates to 528–2,096 tokens),
  align-mode keeps only the last boundary per request → silent-0%-hit
  failure modes; explicitly **not bit-exact** (bf16 snapshots). SGLang's
  MambaRadixCache/Unified Radix Cache (built for Qwen3-Next/3.8) is the most
  advanced: radix nodes carry optional state checkpoints, two LRU lists, and
  **ReplaySSM** for MTP verification — the same records-and-replay idea as our
  MTP capture-verify tape. Verdict: Qwen hybrids are where frontier work is,
  and it is *less* mature than dense caching everywhere public. Our
  exact-boundary fp32 state sidecar would exceed the public state of the art
  on exactness.
- **Routing**: sglang-router (approximate per-worker radix from routing
  history — no worker events; cache_threshold 0.5; load-imbalance override),
  Dynamo (event-fed radix + overlap credit decayed under load; approx mode
  trusts only its own history — the right analogue for untrusted providers),
  Mooncake (512-token chained hashes; replicate hot prefix only when transfer
  beats recompute — on our links it never does). Our receipt-driven holder
  model + capped discount is architecturally equivalent to Dynamo's
  decay-under-load, with stronger (proof-backed) signals.
- **Pricing**: market converged on ~0.1× cache reads (Anthropic, OpenAI
  GPT-5.6+, Gemini 90% off; DeepSeek's disk tier ~1/30–1/50×; DashScope
  implicit 0.2×/explicit 0.1×). OpenAI's `prompt_cache_key` is the precedent
  for exposing affinity to clients. **Today our billing pays full prompt
  tokens on a hit** — nothing in `coordinator/billing/` references cache
  fields. That's provider-favorable (they get paid for skipped work) and
  consumer-neutral (latency only). A pricing decision is a product question
  to schedule, not a blocker.
- **Verifying hits**: no public mechanism proves a provider truly held cache.
  Composition that fits us: our existing chain-hash proof receipts (already
  stronger than anything public) + TTFT-distribution plausibility + (future)
  TOPLOC-style activation commitments. Economic asymmetry helps: faking a hit
  means the provider recomputes at its own cost; the real risk is stale
  recurrent state on hybrids — which is exactly what bit-exactness gates and
  activation commitments catch.

## Part 5 — Per-model enablement analysis

**gpt-oss-20b — first.** Attention-only capability, frozen-full replay proven
bit-exact at tolerance zero on real weights, replay bound only 1,536 tokens,
measured 59.8–79.4% prefill reduction at 4k–8k prompts, warm TTFT 3.57 s vs
4.26 s cache-off. Smallest model (~12 GB) → the per-box KV-capacity cost of a
paged flip is most affordable here. Blockers: none beyond the backend gate.

**gemma-4-26b — second, gated on the window sidecar.** Mechanically works
(bit-exact at 26k–32k proven), but the 25,600-token replay bound puts the
donation floor at 26,624 tokens → only ~2.3% of its traffic is even donatable,
and measured wins near the floor are small/noisy. WS-4.2 exists in master
precisely to delete the replay bound (floor drops to the generic 1,536); it has
never run under a canary. Enabling Gemma = paged flip + sidecar lifecycle
validation (including the unchased "did not reopen after re-preload" e2e
failure and the 57k-token upper-band staging failure). Cross-layer KV sharing
and `attention_k_eq_v` are already covered by the frozen-full test suite.

**qwen3.5-35b / qwen3.6-35b — the prize, one enabler away.** Today: zero reuse
(`supportsPrefixReuse=false`; slot factory refuses the cache; every multi-turn
request cold-prefills its whole history). The enabler is the **recurrent-state
sidecar**: snapshot the 30 GDN layers' fp32 state + conv tail (~61 MiB) at the
donation boundary as a new DBK3 sidecar kind (the WS-4.2 format was built to be
extended — same encryption, TTL, LRU, recovery), restore on exact-boundary
match, adopt only when matched == snapshot boundary (recurrent state cannot be
truncated). After that, Qwen's structure *helps*: all its attention layers are
full (interval-4, no sliding windows), so R = 0 — exact adoption at any
boundary with **no replay at all**, cheaper than Gemma will ever be. Extra
work items: exact-boundary-vs-block-grain policy (start exact-boundary-only;
per-block snapshots multiply the 61 MiB), MTP interplay (our capture-verify
tape already solves the ReplaySSM problem), and the coordinator plan already
handles per-model capability so no Go changes should be needed. **First step:
diff `origin/cursor/qwen-prefix-cache-final-74d1` against this design — it
appears to implement much of it and includes coordinator exact-routing tests.**

**qwen3-vl / multimodal — explicitly out of scope for v1.** Media requests are
excluded at both the coordinator plan and the engine bridge; vision spans would
need image-hash identity in the contract (vLLM does this with mm hashes) — a
later phase. Qwen3VL already declares `supportsPrefixReuse: false` explicitly
on main (Qwen3VL.swift:1899), so the default-derived capability can't lie.

## Part 6 — Scenario matrix

| Scenario | What happens today (if enabled) | Notes / gaps |
|---|---|---|
| Turn 2 lands on same provider, within 15 min | SSD stage (p95 hit ~17 ms) → exact adoption → prefill suffix only | The core win; TTL is the product constraint for slow conversations |
| Turn 2 lands elsewhere (holder busy) | Discount loses to load → cold prefill on new box → it donates and becomes holder #2 (max 4) | By design; spillover = affinity decay, no KV transfer |
| Provider restarted between turns | Index rebuilt by directory scan; blocks rehydrate (proven) | e2e "reopen after re-preload" check failed once on paged arms — unchased, must be green before canary |
| Provider disconnects / cache evicts | Holders dropped / epoch rotation invalidates all its holders | Working as designed |
| Prompt 26k+ (gemma, no sidecar) | Donatable; adoption replays 25,600 tokens | Sidecar removes this class |
| Prompt ~57k (gemma) | Donation never published a holder in test | Unchased upper-band bug; bound staging bytes suspect |
| Dynamic template (`strftime_now`) | `cold_only`, never an error | One production model reportedly affected — identify which |
| Media request | `cold_only` at plan + bridge | v1 scope decision |
| MTP active on adopted request | MTP-safe-on-paged work exists; verify under adoption in canary | Qwen sidecar phase must cover the capture-verify tape |
| Provider fakes a hit | Must recompute anyway to answer correctly (pays the cost); proof receipts + quarantine catch hash lies | Stale-state fraud on hybrids is the real class — bit-exact gate + future activation commitments |
| Cache hit vs TTFT reputation/deadlines | Excluded from calibration; prediction discarded | Already handled |
| Billing on hit | Full prompt-token payment, no discount | Product decision; market is ~0.1× reads |

## Part 7 — Recommended plan

**Phase 0 — decisions and dusting (days).**
- Decide the keystone: per-model paged flips now (recommended), with the
  paged **headroom model** (replace eager quarter-probe slabs with
  residency-sized allocation) as the parallel track that eventually lets
  `.auto` return to paged fleet-wide. Optionally time-box a root-cause of the
  contiguous SSD-tier divergence (the 7/26 evidence — adopted answer equals
  the cold answer of a *longer* prompt — smells like a boundary/anchor bug,
  and fixing it would decouple caching from the backend war), but do not gate
  the canary on it.
- Evaluate/revive `cursor/qwen-prefix-cache-final-74d1`.
- Fix the two unchased bugs (restart-reopen; 57k upper band). Update the stale
  architecture doc. Set `EIGENINFERENCE_CACHE_MASTER_KEY` in prod env.

**Phase 1 — gpt-oss canary (a week-ish).** First pull gpt-oss's prompt-length
distribution and confirm enough traffic clears its effective ~3k-token floor
(R=1,536 replay + 1,536 saved-tokens admission) — the same trap that neutered
Gemma's economics (p50 979 tokens, 2.3% donatable); if gpt-oss traffic is
similarly short, fix the floor math before spending a canary. Then a small set
of big-RAM providers get
`engine_v2_kv_backend_by_model = { "gpt-oss-20b" = "paged" }` → they start
advertising protocol v2. Coordinator: `MODE=on` at the pre-staged
PERCENT=1 / QPS=1, then raise per the documented doctrine (one control per
≥30-min clean window, ≥100 plans, full miss→donate→hit lifecycle observed).
Watch: adoption exactness spot checks, stage p95 vs the 1 s gate, discount hit
rate, TTFT delta, token_budget_exhausted on the paged boxes.

**Phase 2 — gemma-4 with the window sidecar.** Same per-model flip on canary
boxes; validate `windowSidecarsWritten`/`windowsRestored` and the collapsed
donation floor; then production raise.

**Phase 3 — Qwen recurrent sidecar (the L-effort item).** Design pass first
(exact-boundary adoption, fp32 snapshots, MTP tape interplay, VL position
anchor co-persist for the 3.6-VL variant); build on the WS-4.2 format; ship as
opt-in per-model; canary same doctrine. This is the biggest TTFT win in the
program and leapfrogs the public stacks on exactness.

**Phase 4 — product surface.** Pricing for cache reads (market: ~0.1×),
optional client affinity key (OpenAI `prompt_cache_key` precedent), TTL as a
paid knob (Anthropic 5 min vs 1 h precedent).

## Open questions

1. Live prod env values (`/etc/d-inference/env` is authoritative; repo says
   MODE never left `off` but the host wasn't inspected).
2. Which production model carries the dynamic-time contract (cold-only today).
3. Fate of the 2026-08-24 Qwen branch — abandoned or pending?
4. Paged headroom model design — the real unlock for fleet-wide `.auto=paged`.
5. Billing/pricing posture for hits (nothing in code ties cache to payment).
6. Root cause of the contiguous SSD-tier divergence (worth knowing even if we
   standardize on paged: it is checkpoint-dependent and was never explained).
