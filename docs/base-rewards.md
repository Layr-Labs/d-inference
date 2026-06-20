# Base Rewards — additive base income on top of what you earn

**Status:** Design proposal · **Date:** 2026-06-06 · **Owner:** Coordinator / Payments

> **"Run a 64GB+ Mac on Darkbloom and even when the network is quiet, you earn
> at least a Netflix subscription — best case, more."**

This document specifies a supply-side base reward for providers during the
cold-start period, designed around one core idea: **the base reward is paid
additively, on top of what the provider earns from real inference — base income,
not a backstop.** Every eligible machine keeps 100% of its organic earnings *and*
its full memory-tier floor; real usage is pure upside on top of a stable base.
Cost is bounded not by clawing the base back against earnings, but by a **fixed
monthly pool** (`FLOOR_POOL_B`, §7) that is prorated into 5-minute settlement
periods, plus a strict **eligibility gate** (attested, online, healthy, linked —
§6). Rewards do not depend on demand.

An optional reduction knob `k` (default **0**) can claw the base back against
earnings if the program ever needs to economize — `k=1` reproduces a pure
`max(earned, floor)` backstop — but the shipped model is additive (`k=0`).

It replaces the earlier `streaming.go` design (a flat `memoryBase + bandwidthBonus`
rate paid on top of per-token earnings), which was unbounded, double-paid, and
idle-farmable. This design is also additive, but unlike streaming.go it is
**pool-bounded, verified-memory-tiered, uptime-gated, and durably settled.**
See [§9 Delta](#9-delta-vs-the-previous-streaming-design).

---

## 1. The question this answers

> *"If a machine is attested, online, healthy, and linked, should it earn a stable
> base — even before the network is busy — and still keep everything it makes
> from real work?"*

Yes. The base reward is **additive base income**: `payout = earned + floor`. A
provider always keeps 100% of organic earnings and receives its full tier floor
on top. This is the strongest, simplest retention promise for cold-start, and it
stays affordable for three reasons:

1. **A hard pool cap, not a per-machine clawback.** Total spend is bounded by a
   fixed monthly pool (`FLOOR_POOL_B`, §7), prorated into 5-minute settlement
   periods and water-filled across eligible machines. We bound cost at the
   *fleet* level instead of means-testing each machine, so the promise to any one
   provider stays clean: your base is never cut because you earned.
2. **A real eligibility gate.** The floor goes only to attested, linked machines
   that are online, healthy, and have a loaded routable model (§6). Demand is not
   required: if the machine is up and eligible during a quiet period, it accrues
   the base reward.
3. **Verified, bounded valuation.** The floor is set by *verified* memory tier
   (§3); no self-reported number can raise a payout (§3b).

The trade-off is stated honestly: additive base income does **not** self-liquidate
per machine — every eligible machine always draws its prorated floor, so the program
runs near the pool cap for as long as it is on. We accept that for a simpler,
stronger provider promise, and bound cost with a fixed monthly pool and explicit
budget decisions rather than a hidden per-machine clawback. Providers see the
balance move quickly because the monthly floor accrues every 5 minutes. The
optional `k` knob (§2) remains if the economics ever demand a reduction.

And it still delivers the worst-case marketing promise: the floor is what a
machine earns when the network is silent — and anything it earns is on top.

---

## 2. The model

For each eligible machine *i*, over a closed 5-minute settlement period *p*:

```
earned_i    = organic per-token earnings in this period      (see §5 for "organic")
floor_i     = monthly memory-tier floor × period/month × availability × slot
base_draw_i = max(0, floor_i − k · earned_i)                 // the ONLY new money printed
payout_i    = earned_i + base_draw_i
```

`k ∈ [0, 1]` is the **reduction rate** — the one knob. *For every $1 a provider
earns on the platform, the base is reduced by $k.*

### The knob, k

| k | Behavior | Cost | When to use |
|---|---|---|---|
| **0** | Flat `earned + floor` — additive base income; each 5-minute prorated floor is paid on top of earnings. | Bounded by the prorated pool: `Σ floor` water-filled to `≤ FLOOR_POOL_B × period/month`; does **not** self-liquidate. | **Shipped default.** |
| 0.5–0.8 | Base reduces *slower* than earnings rise; base phases out at `earned = floor / k`. | Lower than additive, higher than `k=1`. | If you want to economize while still rewarding the sub-floor ramp. |
| 1.0 | `payout = max(earned, floor)` — base is a pure backstop; it vanishes when `earned = floor`. | **Cheapest;** self-liquidates as demand grows. | Legacy backstop if the pool must stretch much further. |

**Worked example — 64GB M4 Max, floor = $18:**

*k = 0 (additive base income, shipped):*

| Earned / mo | Base draw | **Total payout** | Network cost |
|---|---|---|---|
| $0  | $18 | **$18** | $18 |
| $9  | $18 | **$27** | $18 |
| $18 | $18 | **$36** | $18 |
| $30 | $18 | **$48** | $18 |

The provider keeps 100% of earnings and the full $18/month floor on top, paid in
5-minute increments. Network cost holds at the prorated floor (bounded by the
prorated pool); real usage is pure upside. **This is the "base income + keep
everything you earn" mechanic.**

*k = 1 (legacy max backstop):*

| Earned / mo | Base draw | **Total payout** | Network cost |
|---|---|---|---|
| $0  | $18 | **$18** | $18 |
| $9  | $9  | **$18** | $9  |
| $18 | $0  | **$18** | $0  |
| $30 | $0  | **$30** | $0  |

Here the base reduces dollar-for-dollar and self-liquidates as the provider
out-earns the floor — cheapest, but a weaker provider promise (a "dead zone"
where extra usage below the floor doesn't raise take-home).

### Recommendation: ship `k = 0` (additive base income)

We ship `k = 0`: each prorated floor is paid on top of earnings. Reasons:

- **Strongest retention promise.** "Keep everything you earn, plus a base for
  staying online" beats "we top you up to a floor" — there is no dead zone where
  extra usage fails to increase take-home.
- **The pool already bounds cost.** Spend is capped at `FLOOR_POOL_B` regardless
  of `k`; additive just means the program runs near that cap while it is on, which
  we accept for cold-start.
- **The gate already prevents farming.** A machine cannot collect the floor by
  refusing work (§6), so additivity creates no idle-income loophole.

Cost honesty: unlike `k = 1`, additive base income does **not** shrink to $0 per
machine as demand grows — budget it as a roughly flat, pool-sized line for the
program's life, not as a self-liquidating subsidy. If the pool ever needs to
stretch, dial `k` up (0.5–1.0) — the mechanic is already in the code
(`Draw(floor, earned, k)`), default `k=0`.

---

## 3. Per-machine valuation: the floor table

The floor is set by **memory tier** — what models the machine can actually hold,
which is the option value the network is paying to keep warm — then prorated to a
5-minute period, scaled by availability and (if the budget binds) a slot factor.

```
floor_i = floor_tier(verified_memory_i) · period_seconds / seconds_in_month · avail_i · slot_i

avail_i = clamp( (period_uptime_fraction_i − 0.90) / 0.10 , 0 , 1 )   // 0 below 90% uptime, full at 100%
```

| Machine class | Floor / mo (worst case, full eligibility) | "Pay for your Netflix"? |
|---|---|---|
| 16GB Air, <24GB | **$0** — usage only | No — too small for the 20B baseline or useful specialist work |
| 24GB | **$10** | A streaming sub (entry tier) |
| 32GB | **$12** | A streaming sub |
| 48GB M4 Pro | **$16** | Netflix **with ads** ($7.99), *not* Standard |
| **64GB M4 Max** | **$18** | **The anchor — Netflix Standard ($17.99)** ✓ |
| 96GB | $22 | Yes |
| 128GB Ultra | $26 | Yes |
| 192GB Mac Studio | $30 | Yes |
| 512GB | $40 | Yes |

Notes:
- **`avail` is the "stay online" incentive.** Below 90% uptime within a 5-minute
  settlement period the prorated floor ramps toward $0. Uptime is computed from
  the durable `provider_sessions` table (restart-safe), **not** in-memory ticks.
- **Floor tier is capped at *verified* memory** (§6) — a self-reported spec can
  only cap a machine *downward*, never raise its floor.
- **24GB and 32GB are incentivized entry tiers.** They can serve the gpt-oss-20B
  baseline and specialist work (STT, embeddings), and the real fleet skews into
  this range (~27GB average), so paying them brings in the bulk of useful supply.
  They earn while online and eligible, even if demand is quiet.
- **Sub-24GB machines get $0 floor by design.** They can't hold the 20B baseline
  or run useful specialist work; they still earn from real usage.

### Which signals set the floor — and which are trustworthy

| Signal | Source | Trust | Role |
|---|---|---|---|
| Memory tier | serial→model max-memory cap + reported MemoryGB | **capped** | sets `floor_tier` |
| Uptime | `provider_sessions` (durable) | **coordinator** | sets `avail` |
| Trust level | attestation (`hardware` / `self_signed`) | **attested** | eligibility |
| Organic earnings | `ProviderEarning` rows, filtered (§5) | **coordinator** | the reduction (`k · earned`) |
| Self-reported `MemoryGB`, `DecodeTPS`, `requests_served` | heartbeat | **untrusted** | may only cap downward / never raises a payout |

> **Non-negotiable principle: no self-reported number may raise a payout.** See
> §6 for why this is load-bearing (MDM does not attest memory size).

---

## 4. Cost controls

The shipped model keeps the provider promise simple (`earned + base reward`) and
uses explicit controls to bound spend.

### 4a. Per-provider clawback (optional — OFF by default)

This is the `base_draw = max(0, floor − k · earned)` mechanic of §2, with `k`. At
the shipped default `k = 0` it is **inactive**: the full prorated floor is paid
additively and a provider's base never shrinks because it earned. Setting `k > 0`
turns it on per machine, every settlement period, automatically. It is held in
reserve in case the pool must stretch further.

### 4b. Fixed monthly pool (always ON)

`FLOOR_POOL_B` is the hard monthly cap on base-reward money. Each 5-minute
settlement gets a prorated share of that pool. If eligible floors exceed that
period pool, the allocator funds a deterministic subset of machines, protecting
the 48–96GB workhorse tier first (§7). This is the primary cost control for the
additive model.

---

## 5. What counts as "earned" (organic earnings)

"Earned" must be defined on **real** money — it feeds the admin/dashboard
`earned + base` breakdown, the optional `k`-clawback (§2), and the scarcity
ranking when the pool is over-subscribed (§7). Under additive payment there is no
incentive to fake *earnings* (they wouldn't raise the base). "Earned" is defined
tightly:

```
organic_earned_i = Σ ProviderEarning.AmountMicroUSD
                   WHERE Model        ≠ 'base_reward'
                     AND AmountMicroUSD > 0
                     AND consumer_account ≠ provider_account   // excludes self-route
                   over the settlement period
```

- **Self-route excluded.** Self-route settles at $0 today, but a provider can be
  its own consumer through a second account; jobs where the consumer account ==
  the provider's account never count.
---

## 6. Eligibility gate (anti-gaming)

A machine accrues its prorated floor for a 5-minute settlement period **only
while all of these hold**. Floor without these is $0 — unproven capacity earns
nothing (it must not dilute honest providers).

1. **Attested** — trust ∈ {`hardware`, `self_signed`} ≥ `MIN_TRUST`.
2. **Memory capped** — serial→model lookup caps self-reported memory downward;
   unknown models receive $0 until catalogued.
3. **Online ≥ 90%** of the settlement period (else `avail` ramps the floor down).
4. **Healthy** — memory pressure < 0.8, thermal ≠ critical, and the advertised
   model is actually loaded for routing.
### Code realities that gate shipping

These were verified against the coordinator source:

- **MDM `SecurityInfo` carries the serial number but *not* memory size**
  (`coordinator/mdm/mdm.go`). `MemoryGB` arrives only via the self-reported
  heartbeat. A small Mac could otherwise claim 512GB and bank the top tier. **Fix:
  serial→model lookup caps self-reported memory downward; unknown models get $0
  until we explicitly catalogue them.**

### Concentration — per-machine, no per-account cap (default)

Base rewards are paid **per machine, not per account**: an operator running N
real, attested, online Macs contributes N machines of capacity and earns N floors.
We deliberately do **not** cap an account's share by default, because:

- **Attestation is the Sybil defense.** Every machine must be real, attested
  Apple hardware passing the uptime/health/model-loaded gates — you cannot fake
  machines, so a large account share reflects real capacity, not Sybils.
- **The pool already bounds total spend** ($9k), so a per-account cap adds
  nothing to cost control — it only changes *distribution*, toward penalizing
  the honest multi-machine operators that are exactly the supply we want.
- **A per-account cap is itself dodgeable** (split machines across free Privy
  accounts), so it would punish honest single-account operators while a
  determined one routes around it — worst of both.

An optional concentration cap remains available as a knob
(`EIGENINFERENCE_BASE_REWARDS_ACCOUNT_CAP`, default `0` = off; when set it binds
on the **Stripe Connect KYC payout identity**, not the free Privy account, and is
enforced cumulatively across re-settlement runs). Turn it on only if a real
concentration problem appears; the default is per-machine.

---

## 7. Budget — name one number

Under additive base income the pool cap is the *primary* cost control (there is no
per-machine clawback by default), so the worst case is also the expected case — a
number you can pre-commit:

```
period_draw = Σ base_draw_i  ≤  FLOOR_POOL_B × period_seconds / seconds_in_month
```

| Line | Worst case |
|---|---|
| Draw (`FLOOR_POOL_B`) | **≤ $9,000 / mo** — the board number |
| Stripe payout fees | ≤ $500 / mo |
| **All-in ceiling `Z`** | **≈ $9,500 / mo** |
| **Today's actual** (≈600 machines) | **≈ $7,600 / mo** — the cap doesn't bind until ~1,000 machines |
| Optional lifetime cap | ~$40,000 → a money-driven end date independent of demand |

**If eligible floors exceed `B`**, allocate floor slots to **protect the
48–96GB workhorse tier** (rank by value-per-floor-dollar + a reserved sub-pool),
**not** biggest-machine-first — otherwise idle 512GB boxes consume the whole pool
and the workhorse tier the marketing is written for gets $0.

### Honest note on cost (no self-liquidation)

Additive base income (`k = 0`) does **not** self-liquidate: every eligible machine
draws its prorated floor every settlement period regardless of earnings, so the
program runs at roughly the pool cap while it is enabled. Even under the legacy `k = 1` backstop
the per-machine crossover (`earned ≥ floor`) sits **far** above alpha demand — a
64GB Max at ~40 tok/s would need ~105% single-stream (≈ 35% sustained-batched)
utilization to gross its own $18 — so either way this is **a flat ~$8k/mo
retention line for many months**. Plan it as real burn: affordable on a seed
runway, correctly understood as supply-side CAC, and controlled by explicit pool
and lifetime budget decisions (or the optional `k` knob), not by automatic
self-liquidation.

---

## 8. Settlement & restart-safety

- **Per-token earnings** settle live per-job, as today (`CreditProviderAccount`).
- **The base draw** settles every 5 minutes after the period closes: one
  **idempotent** ledger entry per machine, entry type `provider_floor_draw`,
  unique key `(provider_key, epoch_id)`, `ON CONFLICT DO NOTHING`. The provider
  sees a combined "earned + base reward" number and the balance moves quickly.
- **Uptime / `avail`** computed from durable `provider_sessions` intervals
  (union overlapping rows per machine — blue-green deploys leave two open rows);
  an open session accrues only to `min(period_end, last_seen + 90s grace)`.
- **Required fixes:** add `UNIQUE(job_id)` to `provider_earnings` (no uniqueness
  today → a retried settlement double-credits real money); unify the identity
  (`provider_sessions` keys on serial+account, earnings on `provider_key` — add
  `provider_key` to sessions).
- **The in-memory `StreamTracker` is display-only** — never the money
  source-of-truth.

---

## 9. Delta vs the previous `streaming.go` design

Previous (branch `worktree-stream-payments`): flat `memoryBase($6–22) +
bandwidthBonus($4–8)` ≈ $10–30/mo, streamed per-minute, paid **on top of**
per-token.

| | Old | This design |
|---|---|---|
| Relationship to earnings | additive (`base + usage`) | **additive base income** (`earned + floor`; optional `k`-clawback, default off) |
| Total cost | unbounded (`rate × fleet × time`) | **bounded** by `FLOOR_POOL_B` (flat while enabled) |
| Valuation | `memBase + bwBonus` (sum) on **self-reported** specs | memory-tier floor on **verified** memory |
| Eligibility | "warm model loaded" (idle-farmable) | attested + online + healthy + loaded model + linked account + uptime |
| Durability | in-memory, lost every deploy | durable `provider_sessions` + idempotent settlement |
| Demand coupling | none | fleet pool cap (optional per-provider `k`) |

**Keep:** the eligibility-gate concept, the µUSD ledger plumbing, the admin
visibility endpoint, the rough $10–40 envelope. **Drop:** the additive rate
table, the in-memory tracker as source-of-truth, the bandwidth-bonus term.

---

## 10. Marketing — what is actually true

- **Anchor to the qualifying class, never blanket.** "Pay for your Netflix" is
  honestly true only for **64GB+** machines — roughly the top ~18% of a realistic
  Apple fleet (which skews 16–32GB). Lead with: *"Run a 64GB+ Mac and even when
  the network is quiet, you earn at least a Netflix subscription — best case,
  more. Smaller Macs earn from real usage."*
- **Never say "guarantee."** The floor is slot-capped, eligibility-gated, and
  discretionary; "guarantee" contradicts the live `/earn` disclaimer and invites
  a deceptive-practices claim. Use "earnings floor" / "baseline while eligible."
- **Don't call 64GB "typical."** It's the workhorse tier, not the median Mac.
- **Make it verifiable.** Show each provider their tier, floor, uptime%, slot
  rank, and the `earned + base` breakdown in the dashboard.

---

## 11. Phased rollout

**Phase 0 — bounded floor, honest gate, restart-safe (~3 wks).** Floor table +
additive `k=0` base income (prorated floor on top of earnings); eligibility gates
for attestation, uptime, health, loaded model, and linked account; `UNIQUE(job_id)`
+ idempotent `provider_floor_draw` settlement from `provider_sessions`; slot
allocation protecting the workhorse tier; per-machine payout (per-account cap off
by default). Test live-isolated against throwaway Postgres (double-credit,
blue-green double-open, partial-settlement Σ==pool, empty-fleet no-NaN,
pre-attestation unpaid).

---

## 12. Open decisions

1. **`k` (decided)** — ship `k = 0` (additive base income: keep everything you
   earn, plus the prorated floor). The `k` knob stays in the code (default 0) and can
   be dialed up to 0.5–1.0 later to economize if pool pressure demands.
2. **`FLOOR_POOL_B` = $9,000/mo and all-in `Z` ≈ $10,500/mo** — approve as the
   pre-committed ceiling? And a `~$40k` lifetime cap?
3. **48GB tier** — keep at $16 marketed as "Netflix with ads," or raise to ≥$18
   to make it honestly Standard (+~$1–2k/mo worst case)?
4. **Settlement cadence (decided)** — 5-minute settlement periods, prorated from
   the monthly floor/pool, so providers see balances move shortly after they stay
   online.
5. **Entry tiers (decided)** — 24GB ($10) and 32GB ($12) now earn a floor to
   incentivize the common mid-range Macs (they can serve the 20B baseline +
   specialist STT/embeddings work, and the fleet skews into this range). They
   earn while online and eligible. Open sub-question: extend a floor to 16GB for
   specialist-only work, or keep 24GB as the threshold?
