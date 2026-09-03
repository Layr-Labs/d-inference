# Review: PR #686 + mlx-swift-lm #116 (resident "radix" prefix cache) — legitimacy, fit, and what to delete

> Last updated: 2026-08-31 · commit `5d400cf75`

Date: 2026-08-31. Companion to
`docs/reports/2026-08-31-prefix-cache-deep-dive-and-cached-routing-plan.md`
(the deep-dive); this report reviews the two open PRs against that plan.
Sources: full diffs of d-inference #686 (`codex/radix-prefix-cache-integration`,
anupsv, 2026-08-23) and Layr-Labs/mlx-swift-lm #116, master @ b66ee3065,
coordinator receipt/routing code, and the deep-dive's findings.

## TL;DR — three answers

1. **Is it legit?** Yes. The engine-side implementation (#116) is
   architecturally serious vLLM-style work — non-owning index over physical
   pages, generation-checked handles closing page-ID ABA races, all-or-nothing
   transactional retains, conflict quarantine, leaf-biased LRU — with unusually
   strong lifecycle/leak tests. The provider wiring (#686) is careful and
   fail-closed. Caveats: CI never ran (test claims are the author's), and there
   are two real design findings (F1, F2 below) that should block merge until
   addressed or explicitly accepted.
2. **Could it work with d-inference?** Yes, but it is the **third piece of a
   three-piece puzzle and does nothing by itself.** It is inert on the default
   fleet (resident L1 only activates on a resolved-**paged** slot; `auto` still
   resolves contiguous) and it does not touch the `liveKVHeadroom / 4` pool
   sizing that killed the v0.8.0 paged default. Worse, as written it is
   **invisible to cache-aware routing** (F1): a conversation served purely from
   resident memory emits no receipts, so its holder entry dies at the 10-minute
   TTL exactly when the cache is hottest. The keystone for the whole program
   remains the paged capacity/headroom fix; this PR is a same-box accelerator
   that rides along once that lands.
3. **What to delete?** Less than instinct suggests. The exact-caching machinery
   is not slop — it is the **evidence substrate cached routing runs on** in an
   untrusted-provider network. The genuinely deletable surface: v1 cache-receipt
   emission + the coordinator's inert v1 stubs, the stale sections of
   `cache-aware-routing.md`, and contiguous-adoption leftovers. Everything else
   (SSD tier, receipts, evidence sequencer, prompt-contract sidecar, HMAC
   scopes, frozen-full replay, WS-4.2 sidecar) is load-bearing. Details in
   Part 4.

## Part 1 — What the PRs actually build

- **mlx-swift-lm #116** (~2.7k diff lines): a resident prefix cache directly
  over the paged pool's physical pages. Despite the branch name
  (`radix-prefix-cache-integration`) it is the **vLLM automatic-prefix-caching
  design**, not an SGLang radix tree: finalized page-aligned blocks keyed by
  parent-chained SHA-256 hashes (`PagedPrefixBlockIndex`), zero-copy sharing via
  refcounts, zero-ref cached pages kept allocator-visible in an intrusive FIFO
  free queue (`PagedBlockFreeQueue`) with cached pages at the LRU tail. Page
  reuse invalidates every alias through a `PagedKVPageReuseObserver` callback
  *before* the generation increments — stale metadata fails closed.
- **d-inference #686** (~1k diff lines): wires that index in as L1 ahead of the
  encrypted SSD snapshot cache (L2). Advisory `residentPrefixCandidate` probe on
  the bridge; a positive candidate skips SSD staging entirely; the engine
  revalidates generations on its serial queue and falls back cold on a race
  (classified memory-tier, never a fabricated SSD miss). Adds
  `CBv2Usage.prefixCacheTier` so the winning tier is engine-reported. Resident
  hits create no evidence-sequencer state; the PR adds tombstone/expiry handling
  so late SSD donation callbacks after a resident hit can't create immortal
  state. Same kill switch (`DARKBLOOM_PREFIX_CACHE`), same prompt-contract
  identity and per-account cache salts as the SSD tier.

## Part 2 — Implementation-quality verdict (the "legit" question)

**Strengths, verified in the diffs:**

- Correct concurrency split: hashing on the submit thread, advisory probe under
  the index lock, claim (resolve + transactional `retainPages`) confined to the
  engine queue. The probe pins nothing; the claim is all-or-nothing.
- ABA closed properly: per-page `generations` bumped before reuse; handles carry
  (group, page, generation); `retainPages` validates every handle before
  incrementing any refcount; mixed-generation retains leave state untouched
  (tested).
- The chained-step hazard is handled: publication uses the step's immutable
  `computedRanges`, not `scheduler.numComputedTokens`, so in-flight N+1 KV is
  never indexed (tested). MTP publishes only the accepted frontier, after
  rollback reconciliation (tested).
- Conflict quarantine: a same-generation page observed under two content
  identities dissolves every overlapping bundle and quarantines the pages until
  generation reuse; hostile republication stays metadata-bounded (tested with
  256 adversarial salts).
- Leak resistance: 128-cycle publish→hit→release→drain conservation tests over
  page ids, refcounts, reservations, and the free queue.
- Exactness posture is sound: adoption installs the donor's *physical pages* —
  the adopter attends over byte-identical KV, so resident adoption is at least
  as exact as SSD snapshot adoption on paged (which the 2026-07-26 six-arm gate
  measured exact). Sliding-window sidecar restores are explicitly refused
  (`requiresExactWindowRestore` → ineligible); plans are re-validated fail-closed
  before any page is retained. No new wrong-answer class.
- Telemetry honesty: a stale advisory candidate is reported as a memory-tier
  refusal, which (verified coordinator-side) cannot trigger the
  `miss_absent` holder-invalidation path. Correct-by-design.

**Verification caveats:** no CI ran on either PR (the only check is a skipped
codesmith job); the listed test results are the author's. #116 merges cleanly
onto the current mlx-swift-lm head (4 commits behind, zero conflicts), but
#686's submodule pin points at the #116 *branch head* and must be re-pinned to
the merged commit. Merge gates: land #116 first, re-pin, run the full suites on
CI, and rerun the paged parity lane.

## Part 3 — Findings, ranked

**F1 — Resident hits are invisible to cache-aware routing; holders decay
fastest for the hottest prefixes.** (composition gap — blocks the routing
canary; latent today since `CACHE_ROUTING_MODE=off` and the fleet is
contiguous)

The evidence sequencer only emits receipts for `tier == .ssd`
(`PrefixCacheEvidenceSequencer.swift:163,218`) and the coordinator only accepts
SSD-tier receipts (`cache_receipts_v2.go:236,348`). Both gates **predate the
PR** (they shipped with #549, 2026-07-17); #686 composes with them, it did not
create them — the PR body's "prevents resident hits from emitting durable
SSD-holder evidence" describes pre-existing behavior, and what the PR genuinely
adds is the tombstone/expiry hygiene. The composed result: turn 1 (cold) stages
SSD, emits lookup + ready, creates a holder with a 10-minute TTL. Turns 2+ hit
resident L1, emit nothing, and the buffered late-donation callback expires
unemitted (and would be rejected coordinator-side anyway — `!attempt.LookupSeen`).
The holder is never refreshed and dies mid-conversation, exactly when the cache
is delivering. A prefix hot in L1 is forgotten by routing sooner than one that
keeps falling through to SSD.

*Fix direction:* emit memory-tier lookup receipts **with anchors** (the PR
currently nils them) and accept them coordinator-side as holder **TTL refresh**
(not creation). This is a small coordinator change and violates the
"zero coordinator changes" preference — deliberately: the provider-only
alternative is emitting SSD-tier receipts for stages that never happened, i.e.
fabricating exactly the evidence the routing design exists to verify. Note the
accepted looseness: refresh-only acceptance lets a holder outlive SSD eviction
on an L1-hot box; it self-corrects via miss-invalidation on the eventual SSD
miss.

**F2 — Any resident candidate suppresses SSD staging, even when SSD holds a
much longer prefix.** (perf-only, second order)

`EngineV2Bridge.swift` skips `ssd.stage()` whenever `residentPrefixCandidate`
is non-nil, and the engine-side tie-break (`residentMatch.matchedTokens >=
snapshotMatched`) never sees the SSD match because nothing was staged. Under
allocator churn L1 evicts mid-prefix while SSD retains 15 minutes, so a 2k-token
L1 remnant can preempt a 50k-token SSD hit. Exposure is bounded by `plan()`
gating (tiny matches are unplannable — gemma's replay bound mostly masks this;
gpt-oss with R=1,536 is the exposed shape). *Fix direction:* compare the
advisory L1 match length against an SSD **index-only probe before deciding to
skip staging. Note: no such probe API exists today — `SSDPrefixCache` only has
`stage()` — so the fix requires adding a cheap longest-block-run peek.*

**F3 — No admission-capacity gain, and cache capacity is bounded by the starved
pool.** (inherent, acknowledged in the PR)

Every adopter still reserves its full worst-case page demand ("preserves the
backend's nonthrowing-decode guarantee"); zero-ref cached pages remain
allocator-visible so the cache steals no admission capacity — but it also adds
none, and its effective size is (usable pages − actually-allocated pages) of a
pool that `liveKVHeadroom / 4` pins to a quarter of the contiguous grant.
`PagedKVPhysicalCapacityPolicy.swift` is byte-identical since v0.8.0. The PR is
honest about this; it just means the v0.8.1 revert calculus is untouched.

**F4 — Minor:** the full prompt hash chain is computed twice per request
(advisory probe on the bridge, again at submit). Cheap SHA-256 host work;
worth passing the probe through, not worth blocking on.

**F5 — Process:** no doc updates ship with #686 —
`docs/architecture/cache-aware-routing.md:12` ("the encrypted SSD cache is the
only production reusable prefix tier") and `:88` (holder lifecycle) become
inaccurate the moment it merges. The deep-dive already flagged `:207` stale in
the other direction.

## Part 4 — Keep/delete: the exact-caching machinery

Plainly: **most of it should stay.** The "naive" part of the original work was
not exactness — it was (a) coupling cache construction to a fleet-wide backend
default that then got reverted for capacity, and (b) making SSD the only
evidence-bearing tier. The bit-exact-or-cold contract is the *right* call for a
network that pays untrusted providers per token: a cache hit that changes the
answer is indistinguishable from a provider serving degraded output, and the
2026-07-26 six-arm data (contiguous silently truncating ~1 in 43 flagship
requests in the exposed band) is the receipt. Public stacks accept warm-vs-cold
drift because they run their own hardware; we cannot.

**Keep (load-bearing):** the SSD tier (donation/adoption/staging/TTL/LRU —
survives restarts, generates the evidence, and is the only tier bigger than the
paged pool), `PrefixCacheEvidenceSequencer` + v2 receipts, the prompt-contract
sidecar + HMAC scopes, coordinator holders/hints/capped-discount, frozen-full
replay, and the WS-4.2 window sidecar (gemma's economics depend on it).
Resident L1 cannot replace the SSD tier: it dies on restart, is bounded by the
starved pool, and — per F1 — produces no routing evidence.

**Delete (the actual slop):** v1 cache-receipt emission on the provider and the
coordinator's hard-stubbed v1 acceptance (`cache_receipts.go:71–77`) once the
v2 canary is green; the stale doc sections (fix in the same PR as F1); the
`outcome == .disabled && hitTokens > 0 → .hit` compat shim in
`EngineV2Bridge+PrefixCache.swift` once no older engine pin needs it; and any
remaining contiguous-adoption eligibility scaffolding (already dead via
`adoptionIsExact` refusing construction — deleting it is cleanup, not risk
reduction). This is a modest list on purpose; the deep-dive's architecture
survey is why.

## Part 5 — How this sequences with the enablement plan

The deep-dive's phase plan stands; these PRs slot in as follows:

- **Phase 0 additions:** land #116 (after CI + rebase), then #686 **with F1 and
  F2 fixed** (memory-tier receipt refresh + SSD index peek) and the doc updates.
  This makes every future paged flip automatically carry a zero-copy L1.
- **Keystone unchanged:** per-model paged flips on big-RAM boxes now
  (`engine_v2_kv_backend_by_model`), headroom-model redesign as the track that
  lets `.auto` return to paged. Nothing in these PRs advances or blocks that.
- **gpt-oss canary** (Phase 1) is where L1 first matters — full-attention +
  alternating window, R=1,536, and the model most exposed to F2; fix F2 before
  the canary, or the canary's hit-quality numbers will be polluted.
- **Qwen is untouched by all of this.** `supportsPrefixReuse=false` gates the
  resident config exactly as it gates SSD (verified in the #686 diff:
  `modelCapabilities.supportsPrefixReuse ? residentPrefixCache : nil`). The
  recurrent-state sidecar — and evaluating
  `origin/cursor/qwen-prefix-cache-final-74d1` — remains its own track and is
  still the biggest prize in the program.

## Open items

1. Get CI green on both PRs; land #116 → re-pin #686 → full suites + paged
   parity lane.
2. Decide the F1 evidence-contract extension (provider anchors + coordinator
   refresh-only acceptance) — small Go change, needs a design sign-off since it
   widens what a receipt can mean.
3. Add the SSD index peek API for F2.
4. The deep-dive's open questions all still stand (headroom model, Qwen branch
   fate, the two unchased v0.8.0 bugs, billing posture).
