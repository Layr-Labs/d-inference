# Provider Referrals — earn a share of what your referrals earn

**Status:** Design proposal · **Date:** 2026-08-18 · **Owner:** Coordinator / Payments · **Companion:** [base-rewards.md](base-rewards.md)

> **"Refer a provider. Earn 20% of everything their Macs earn for their first
> 6 months — paid on top. They keep 100% of theirs."**

This document specifies a supply-side referral program whose goal is to flood
the network with new attested provider machines, at bounded cost, with a
mechanic that fits in one sentence. The core idea: **the referral reward is a
share of the referred provider's actual earnings** — organic inference payouts
*plus* base-reward floor draws — paid additively to the referrer from a capped
monthly program pool. Because the reward is defined on earnings, it inherits
every quality and anti-gaming gate that earnings already have (attestation,
uptime, health, loaded model — [base-rewards.md §6](base-rewards.md)), and it
needs **no new eligibility machinery of its own**. A referred provider that
delivers nothing pays its referrer nothing.

It launches at a promotional **20%** rate and steps down to a **10%** evergreen
rate as supply targets are hit. Rates are **locked per referral** at
activation — early recruiters keep their promo rate for the full window.

---

## 1. The question this answers

> *"How do we turn every existing provider into a recruiting channel, pay only
> for supply that actually comes online and performs, and bound the total spend
> in advance?"*

Three fundamental truths drive the design:

1. **A referral program is paid supply acquisition — CAC vs LTV.** The value of
   a provider to the platform is the routing fee on the traffic it serves over
   its lifetime. The correct spend is therefore proportional to *delivered
   value*, never to sign-ups. Flat sign-up bounties decouple payout from value
   and are the #1 fraud magnet in referral programs; a share-of-earnings reward
   is fraud-resistant by construction.

2. **Reality check: the platform fee in code is 0% today.** The headline
   business model is a 10% routing fee, but `platformFeePercent = 0` during the
   public alpha (`coordinator/payments/pricing.go`;
   [architecture/overview.md](architecture/overview.md) documents the
   correction). The existing consumer referral (`coordinator/billing/referral.go`)
   pays a share *of the platform fee* and is therefore **dormant — it pays $0
   per referral right now**. Any provider-referral design funded purely from the
   fee would acquire nobody. That is why this design keys the reward off
   provider **earnings** (which are real today via base rewards) and funds it
   from a capped program pool. When the fee turns on at 10%, the organic-traffic
   portion of the program becomes approximately self-funding with **no design
   change** (§4).

3. **During cold-start, provider income is dominated by base rewards.** The
   floor ($10–$40/mo per machine from the $9k/mo pool) is the thing a referred
   provider reliably earns from day one. A referral share that *includes* floor
   draws pays the referrer real money immediately — which is what makes the
   program actually motivating before organic traffic scales. The share is paid
   from the referral pool, on top of the base pool; the referred provider's own
   floor is never touched.

---

## 2. The model

Reuse the existing referral graph unchanged: one code per account
(`referrers`), one referrer per account (`referrals`, PK `referred_account`),
self-referral blocked (`coordinator/billing/referral.go`). The new part is a
provider-side accrual on top of that graph.

For each provider-earning event settled to a referred account:

```
bonus = rate_locked × earning_amount / 100        // micro-USD, integer division
```

credited to the **referrer's withdrawable balance**, subject to:

| Rule | Value | Why |
|---|---|---|
| Earning events that count | organic inference payouts (`CreditProviderAccount`) + base-reward floor draws (`SettleProviderFloorDraw`) | The two — and only two — places provider money is created. Both are already attestation-, uptime-, and health-gated. |
| Earning events that do NOT count | referral rewards, admin credits/rewards, migration entries, self-route (settles at $0 already) | Single-level only — no pyramid recursion; no rewards on printed money. |
| Window | **6 months** from *activation* | Activation = the referred account's **first provider earning event**, not code-apply time. Parked codes don't burn the window; the clock starts when real supply comes online. |
| Rate | live program rate, **locked at activation** onto the referral | 20% at launch → 15% → 10% evergreen (§6). Locked rates are never retroactively cut — trust is a growth asset. |
| Paid | **on top** — the referred provider keeps 100% of its own earnings | A code must never make the referred party worse off, or attach rates collapse. Zero downside ⇒ everyone uses a code. |
| Per-referrer cap | **$500/mo** (knob) | Bounds single-actor extraction; keeps top-referrer economics "great side income," not "arbitrage business." |
| Program pool | **$2,000/mo** hard cap (knob) | When the month's pool is spent, accrual stops until next month. No proration, no water-filling — a bonus is not a promise, unlike the floor. |

One sentence for the provider dashboard: *"The rate live when your referral's
Mac starts earning is locked in for their entire 6 months."*

### Formula summary

```
eligible(t)  = activated_at ≤ t < activated_at + 180d
bonus        = rate_locked × earning / 100
             gated by:  month_to_date(referrer)  < REFERRER_CAP
                        month_to_date(program)   < POOL
```

That is the whole program. Three knobs: rate, pool, per-referrer cap.

---

## 3. Why share-of-earnings and not a bounty (anti-abuse from first principles)

The reward is a strict subset of money the platform already decided to pay,
gated by machinery that already exists:

- **You cannot fake a machine.** Organic payouts require serving real routed
  traffic on an attested provider; floor draws require `hardware`/`self_signed`
  trust, verified memory tier, ≥90% uptime from durable `provider_sessions`,
  health, and a loaded routable model ([base-rewards.md §6](base-rewards.md)).
  The referral bonus inherits every one of these gates for free. **No new
  eligibility system is built.**
- **Junk referrals self-neutralize.** A referred account that installs and
  vanishes earns $0 ⇒ referrer gets $0. There is no milestone-verification
  machinery to build or game.
- **No clawbacks needed.** Bonuses accrue only on already-settled earnings —
  there is nothing to reverse.
- **Self-sybil is bounded and half-tolerable.** The worst realistic abuse: an
  operator splits their fleet across two accounts and self-refers, leaking the
  referral rate on earnings we were paying anyway — while still adding real,
  attested supply. This mirrors the base-rewards concentration analysis
  ([base-rewards.md §6](base-rewards.md), "Attestation is the Sybil defense"):
  bounded by the per-referrer cap and the pool, so we deliberately do **not**
  build a fraud system for it. Cash-out already passes Stripe Connect KYC
  (`coordinator/billing/stripe_connect.go`); a log-only flag on
  referrer/referred pairs sharing a Stripe payout identity is the cheap future
  backstop if data ever shows a problem.

What is deliberately **not** in the design (the delete pass):

- **No flat sign-up bounty** — decouples payout from value; fraud magnet;
  requires milestone verification.
- **No multi-level rewards** — pyramids are complexity plus regulatory smell.
  `provider_referral_reward` entries are excluded from "earnings," which makes
  recursion structurally impossible.
- **No per-referral decay curves** — "reduce it slowly" (§6) is done with
  cohort-locked rate steps, not per-referral time decay. A decay curve cannot
  be communicated in one sentence and is hell to reconcile.
- **No second code namespace** — provider referrals ride the existing
  `referrers`/`referrals` tables and endpoints.
- **No referred-side discount in v1** — one payout keeps tracking trivial; a
  double-sided sweetener is an open decision (§10).
- **No proration when the pool exhausts** — accrual just stops for the rest of
  the month. Alert at 80% utilization and raise the knob if it binds.

---

## 4. Economics

### Payback math at the target 10% fee

With a 10% routing fee, provider payout is 90% of GMV. A referral at rate *r*
of provider earnings costs `r × 0.9 × GMV`:

| Rate | Bonus as % of GMV | vs the 10% fee | Reading |
|---|---|---|---|
| **20% (launch)** | 18% | ~1.8× the fee | Deliberate promo overspend, bounded by the pool — explicit growth investment. |
| 15% (step) | 13.5% | ~1.35× the fee | Transition. |
| **10% (evergreen)** | 9% | inside the fee | **Self-funding**: the platform gives up ~90% of its fee on referred traffic during the 6-month window, then keeps 100% for the provider's remaining lifetime. Effective CAC on organic traffic ≈ $0. |

Provider lifetime far exceeds 6 months, so LTV/CAC is strongly positive at
every rate. Today (fee = 0%, organic traffic small) the real spend is the
share on floor draws, which the pool bounds.

### What a referrer actually makes (at the 20% launch rate)

| Referred machine | Referral's earnings / mo | Referrer's bonus / mo |
|---|---|---|
| 24GB Mac mini, ≥90% uptime, quiet network | $10 floor | $2.00 |
| 32GB MacBook | $12 floor | $2.40 |
| 64GB M4 Max | $18 floor | $3.60 |
| 512GB Mac Studio, some traffic | $40 floor + $60 organic | $20.00 |
| **Portfolio: 10 mixed machines** | — | **≈ $30–80/mo passive, 6 months** |

Honest read: a single referral is beer money; the pitch is the **portfolio**
("post your link in your Mac community, every machine that joins pays you for
6 months") and the **zero marginal effort**. Real enough to motivate sharing a
link; too small to build a fraud business on — which is the correct place on
that curve.

### Worst-case spend

```
monthly spend = min( POOL,  Σ rate_locked × referred_earnings )
```

| Line | Worst case |
|---|---|
| Absolute ceiling | **$2,000/mo** — the pool knob, pre-committed |
| If 100% of today's floor draws were referred at 20% | ≈ $1,520/mo (20% × ~$7.6k actual base spend) — the pool would not bind |
| Expected at launch (referred fraction ≪ 100%) | low hundreds/mo |

The pool is a circuit breaker, not a rationing device. At $2k/mo and 20%, it
supports $10k/mo of referred-provider earnings — more than the entire current
base-rewards spend.

---

## 5. Settlement, storage, and tracking (implementation map)

The program is one accrual function called from the two existing money hooks,
one table, one ledger type, and three knobs.

| Piece | Design |
|---|---|
| Attribution | Existing `referrers` / `referrals` tables and `POST /v1/referral/register`, `POST /v1/referral/apply` — unchanged. Auto-generate a code at first device link (`api/device_auth.go` approve path) for accounts without one, so every provider has a shareable link with zero setup. Custom codes still supported. |
| Activation row | New table `provider_referral_activations(referred_account PK, referrer_account, rate_percent, activated_at, expires_at)` — created lazily on the referred account's first provider earning event, locking the then-live rate. |
| Ledger | New entry type `provider_referral_reward`, credited via `CreditWithdrawable` to the referrer (same plumbing as the existing `referral_reward`). Withdrawable via the existing Stripe Connect flow. |
| Accrual hooks | Exactly two call sites: after `CreditProviderAccount` in `handleComplete` (`coordinator/api/provider.go`) and after a credited `SettleProviderFloorDraw` (`coordinator/payments/baserewards/engine.go`). One shared `AccrueProviderReferralBonus(referredAccount, amount, sourceKey)` in `coordinator/billing/`. |
| Idempotency | Bonus keys derive from the source event (`prref:{job_id}`, `prref:floor:{epoch}:{provider_key}`) and settle inside/behind the source's existing idempotency (`provider_earnings` UNIQUE `job_id`; floor draws UNIQUE `(provider_key, epoch_id)`). A re-settled source can never double-pay the bonus. |
| Caps | Month-to-date sums over `provider_referral_reward` ledger entries (per referrer and program-wide). No new counters table; the ledger is already the source of truth. |
| Knobs | `EIGENINFERENCE_PROVIDER_REFERRAL_RATE_PCT` (0 = program off — same enable pattern as base rewards), `EIGENINFERENCE_PROVIDER_REFERRAL_POOL_MICRO_USD`, `EIGENINFERENCE_PROVIDER_REFERRAL_CAP_MICRO_USD`. Window fixed at 180 days unless data demands a knob. |
| Referrer stats | Extend `GET /v1/referral/stats`: referred providers (total / active this month), locked rate + window expiry per referral, month-to-date and lifetime bonus. |
| Console UI | "Refer providers" card on `/earn` and `/providers`: referral link (`https://darkbloom.dev/earn?ref=CODE`), live stats, projected-earnings line ("a 64GB Mac referral ≈ $3.60/mo to you"). The `/earn` page pre-fills `?ref=` into signup. |
| CLI touchpoint | `darkbloom status` footer prints the referral link + the one-sentence pitch. Providers live in Mac communities; the link travels where the audience is. |
| Observability | DogStatsD: `referral.provider.bonus_micro_usd` (counter), `referral.provider.active_referred` (gauge), `referral.provider.pool_utilization` (gauge, alert at 80%). Admin: month-to-date spend vs pool, top referrers, cohort table (existing `admin-ui` referrers query extends naturally). |

Metrics of record for the growth loop:

- **Weekly new attested referred machines** (the goal metric)
- **Active referred machines** (attested + earned this week)
- **Effective CAC** = month-to-date program spend ÷ new active referred machines
- **K-factor** = referred providers per active provider

---

## 6. Promotional taper — the growth playbook

The single rate knob steps down on supply milestones; every step is announced
in advance, and every announcement is itself a growth event ("last week at
20%"). Locked rates make each step-down an urgency lever instead of a betrayal.

| Phase | Rate | Trigger to step down | Notes |
|---|---|---|---|
| **0 — Founding recruiters (launch)** | **20%** | weekly new-machine adds hit target, or pool utilization > 60% | Announce loudly with the base-rewards pitch: "your referral's Mac earns a floor from day one — you earn 20% of all of it." |
| **1 — Step** | 15% | same criteria | Ship the CLI touchpoint + a simple top-referrers leaderboard here to refresh attention. |
| **2 — Evergreen** | 10% | — | Approximately self-funding once the 10% platform fee is live (§4). Revisit whether the organic component still needs the pool at all (the floor-share component keeps it). |

Rollout of the code itself is one phase: schema + accrual + stats + earn-page
card, tests live-isolated against throwaway Postgres per repo policy
(activation rate-lock, window expiry, cap hard-stop, idempotent double-settle,
single-level exclusion, self-referral rejection, memory + postgres store
parity).

---

## 7. Delta vs the existing consumer referral

| | Consumer referral (shipped, dormant) | Provider referral (this design) |
|---|---|---|
| Attribution | consumer account that pays for inference | account whose machines **earn** |
| Reward base | share of **platform fee** (20% of 0% = **$0 today**) | share of **provider earnings** (real today via floors) |
| Funding | carved out of the fee | capped program pool; organic share ≈ fee-funded at evergreen rate once fee is 10% |
| Duration | permanent | 6 months per referral, rate-locked |
| Caps | none | per-referrer $500/mo + $2k/mo pool |
| Codes / graph | `referrers` + `referrals` | **same tables, same endpoints** |
| Ledger type | `referral_reward` | `provider_referral_reward` |

Both programs coexist on one referral graph: refer someone who *spends*, earn
fee share (when the fee is live); refer someone who *provides*, earn the
provider bonus. One code, one link, both sides of the marketplace.

---

## 8. Marketing — what is actually true

Same honesty rules as [base-rewards.md §10](base-rewards.md):

- Lead with the true sentence: *"Earn 20% of everything your referrals' Macs
  earn for their first 6 months — on top, they keep 100%."*
- **Never say "guarantee."** The bonus is pool-capped and the program rate
  steps down; say "current rate," "locked for your referral's window."
- Anchor expectations with the tier table (§4), not a cherry-picked 512GB
  Studio. The honest headline is the portfolio number.
- Make it verifiable: the stats card shows each referral's locked rate, window
  countdown, and month-to-date bonus — every number reconcilable against the
  ledger.

---

## 9. Cost honesty

At launch rates this is real burn on top of base rewards, bounded at
**$2k/mo** by the pool — budget ceiling ≈ $11k/mo across both supply programs
($9k base + $2k referral). Unlike base rewards it is **not** flat: spend scales
with referred earnings and steps down with the taper, and the organic component
inverts into fee-funded (≈ zero net) at the evergreen rate once the 10% fee is
live. The floor-share component ends when cold-start ends — the two programs
are coupled by design and sunset together.

---

## 10. Open decisions

1. **Launch rate** — 20% proposed. 25% doubles the headline pop for ~$0.50/mo
   more per referred workhorse machine; the pool bounds either. Decide on
   announcement, not economics.
2. **Window** — 6 months proposed. 12 months doubles liability duration for
   modest extra pull; prefer concentrating spend in cold-start.
3. **Floor draws at full rate** — proposed yes: floors are where referred
   earnings live today, and paying on them is the entire point during
   cold-start. Alternative (half rate on floors) saves little and breaks the
   one-sentence pitch.
4. **Double-sided sweetener** — give the *referred* provider a small boost
   (e.g. +10% floor for month one)? Deferred: it complicates the base-rewards
   pool accounting for marginal extra pull. Revisit if attach rates disappoint.
5. **Rate-lock timing** — locked at **activation** (first earning event)
   proposed: transfers urgency to getting the Mac online, which is the goal
   metric. Locking at code-apply time is the alternative if recruiters complain
   about the gap.
