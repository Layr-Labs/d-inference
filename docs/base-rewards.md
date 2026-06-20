# Base Rewards — an earnings floor that shrinks as you earn

**Status:** Design proposal · **Date:** 2026-06-06 · **Owner:** Coordinator / Payments

> **"Run a 64GB+ Mac on Darkbloom and even when the network is quiet, you earn
> at least a Netflix subscription — best case, more."**

This document specifies a supply-side base reward for providers during the
cold-start period, designed around one core idea: **the base reward is reduced,
dollar-for-dollar, by what the provider already earns from real inference.** A
provider making money on the platform draws little or no subsidy; an idle
provider is topped up to a floor. The subsidy therefore targets exactly the
machines that need it and **self-liquidates** as demand grows.

It replaces the earlier `streaming.go` design (a flat `memoryBase + bandwidthBonus`
rate paid *on top of* per-token earnings), which was unbounded, double-paid, and
idle-farmable. See [§9 Delta](#9-delta-vs-the-previous-streaming-design).

---

## 1. The question this answers

> *"If you're making money through the platform, we reduce the number — does that
> make sense?"*

Yes. It is the single most important property for making the subsidy affordable.
Three reasons:

1. **It means-tests the subsidy.** A fixed subsidy budget goes furthest when it
   is spent only on providers below the floor. Paying base reward to a provider
   already grossing more than the floor is pure waste.
2. **It is self-liquidating.** Total subsidy = Σ of the gaps between each
   machine's floor and its earnings. As real demand grows and earnings rise, the
   gap — and therefore the cost — drifts to **zero on its own**, with no clawback
   and no announcement.
3. **It never double-pays.** The old design paid `base + usage`. This pays the
   *greater* (or a tapered blend), so a busy machine is never handed a full base
   on top of a full paycheck.

And it still delivers the worst-case marketing promise: the floor is what a
machine earns when the network is silent.

---

## 2. The model

For each eligible machine *i*, over a monthly epoch *e*:

```
earned_i    = organic per-token earnings this epoch          (see §5 for "organic")
floor_i     = memory-tier floor × availability × slot        (see §3)
base_draw_i = max(0, floor_i − k · earned_i)                 // the ONLY new money printed
payout_i    = earned_i + base_draw_i
```

`k ∈ [0, 1]` is the **reduction rate** — the one knob. *For every $1 a provider
earns on the platform, the base is reduced by $k.*

### The knob, k

| k | Behavior | Cost | When to use |
|---|---|---|---|
| **1.0** | `payout = max(earned, floor)` — base is a pure backstop; it vanishes exactly when `earned = floor`. | **Cheapest.** Total draw = `Σ max(0, floor − earned)`. | **Recommended for launch.** |
| 0.5–0.8 | Base reduces *slower* than earnings rise, so total take-home always increases with effort; base phases out at `earned = floor / k`. | Higher (you pay base + part of earnings in the ramp). | If you want to preserve marginal incentive to chase demand in the sub-floor zone. |
| 0 | Flat `earned + floor` (the old additive model). | Unbounded. | **Never.** |

**Worked example — 64GB M4 Max, floor = $18:**

*k = 1 (pure floor, recommended):*

| Earned / mo | Base draw | **Total payout** | Network cost |
|---|---|---|---|
| $0  | $18 | **$18** | $18 |
| $9  | $9  | **$18** | $9  |
| $18 | $0  | **$18** | $0  |
| $30 | $0  | **$30** | $0  |

As the provider earns more, the base reduces dollar-for-dollar; total stays at
the Netflix floor until they out-earn it, then they keep 100%. Network cost falls
to zero. **This is the "reduce the number as you make money" mechanic.**

*k = 0.5 (shared ramp):*

| Earned / mo | Base draw | **Total payout** | Network cost |
|---|---|---|---|
| $0  | $18.00 | **$18.00** | $18.00 |
| $9  | $13.50 | **$22.50** | $13.50 |
| $18 | $9.00  | **$27.00** | $9.00  |
| $36 | $0.00  | **$36.00** | $0.00  |

Here total take-home always rises with earnings (no dead zone), the base phases
out at 2× the floor, and it costs more.

### Recommendation: ship `k = 1`

The only downside of `k = 1` is the "dead zone": between $0 and the floor,
earning an extra dollar of usage doesn't increase take-home. In a normal sales
draw this weakens the incentive to work. **Here it doesn't matter**, because:

- At alpha demand almost every machine earns ≈ $0 organically, so it sits at the
  full floor regardless — the dead zone is empty.
- The **eligibility gate (§6) already forces real serving** — a machine cannot
  collect the floor by refusing work; it must pass coordinator probes / serve
  real dispatched jobs. The incentive to serve lives in the gate, not the payout
  curve.

So `k = 1` (`payout = max(earned, floor)`) is the cheapest, cleanest, and easiest
to explain: *"we top you up to your floor; out-earn it and you keep everything."*
`k` can be dialed down later if you decide to reward the ramp.

---

## 3. Per-machine valuation: the floor table

The floor is set by **memory tier** — what models the machine can actually hold,
which is the option value the network is paying to keep warm — then scaled by
availability and (if the budget binds) a slot factor.

```
floor_i = floor_tier(verified_memory_i) · avail_i · slot_i

avail_i = clamp( (uptime_fraction_i − 0.90) / 0.10 , 0 , 1 )   // 0 below 90% uptime, full at 100%
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
- **`avail` is the "stay online" incentive.** Below 90% monthly uptime the floor
  ramps toward $0; this replaces the old per-minute accrual. Uptime is computed
  from the durable `provider_sessions` table (restart-safe), **not** in-memory
  ticks.
- **Floor tier is capped at *verified* memory** (§6) — a self-reported spec can
  only cap a machine *downward*, never raise its floor.
- **24GB and 32GB are incentivized entry tiers.** They can serve the gpt-oss-20B
  baseline and specialist work (STT, embeddings), and the real fleet skews into
  this range (~27GB average), so paying them brings in the bulk of useful supply.
  They earn only while actually serving (the work gate), so the floor never
  rewards an idle small machine.
- **Sub-24GB machines get $0 floor by design.** They can't hold the 20B baseline
  or run useful specialist work; they still earn from real usage.

### Which signals set the floor — and which are trustworthy

| Signal | Source | Trust | Role |
|---|---|---|---|
| Memory tier | serial→model lookup + tier-sized correctness probe | **verified** | sets `floor_tier` |
| Uptime | `provider_sessions` (durable) | **coordinator** | sets `avail` |
| Trust level | attestation (`hardware` / `self_signed`) | **attested** | eligibility |
| Organic earnings | `ProviderEarning` rows, filtered (§5) | **coordinator** | the reduction (`k · earned`) |
| Self-reported `MemoryGB`, `DecodeTPS`, `requests_served` | heartbeat | **untrusted** | may only cap downward / never raises a payout |

> **Non-negotiable principle: no self-reported number may raise a payout.** See
> §6 for why this is load-bearing (MDM does not attest memory size).

---

## 4. The two reductions

There are two independent "reduce the number as money is made" levers. Both
point the same direction; ship the first now, the second when revenue appears.

### 4a. Per-provider (the centerpiece — *your* base shrinks as *you* earn)

This is the `base_draw = max(0, floor − k · earned)` mechanic of §2. It operates
per machine, every epoch, automatically. No configuration, no announcements.

### 4b. Per-network (the program sunsets as the *platform* earns)

A global multiplier on the floor that fades the whole program as real network
revenue grows:

```
floor_i  ← floor_i · taper
taper    = min( calendar_glide , revenue_taper )
revenue_taper = clamp( 1 − fleet_organic_revenue_30d / TARGET_REVENUE , 0 , 1 )
calendar_glide: 1.0 for days 0–30, linear to a residual floor over days 30–90
```

- **`revenue_taper` keys on absolute revenue, not a utilization ratio.** A
  utilization ratio (`active/capacity`) is a positive-feedback trap: defunding
  supply shrinks capacity, which *raises* measured utilization, which defunds
  further — collapsing the fleet at constant low demand. Absolute revenue is
  monotone in real demand and immune to that loop.
- **Off-ramp:** when `fleet_organic_revenue` exceeds `TARGET_REVENUE`
  (≈ 3× the pool) for two consecutive months, retire the cold-start floor and run
  on usage (plus the eventual platform fee).

### Cliff guard (applies to both)

No machine's **total** monthly income (earned + base) may fall more than **30%
month-over-month** from a taper change, and any reduction to the program ships
with **30 days' notice**. This relocates cliff-prevention from a fragile
fleet-average assumption to a per-machine guarantee, and is the cheapest defense
against churn and "bait-and-switch" complaints.

---

## 5. What counts as "earned" (organic earnings)

The reduction must key on **real** money, or providers will manufacture fake
earnings to... no — the incentive runs the other way: fake earnings would
*reduce* their base. The real risk is the inverse: fake "served work" to clear
the **eligibility gate** (§6). Regardless, "earned" is defined tightly:

```
organic_earned_i = Σ ProviderEarning.AmountMicroUSD
                   WHERE Model        ≠ 'base_reward'
                     AND AmountMicroUSD > 0
                     AND consumer_account ≠ provider_account   // excludes self-route
                     AND not a synthetic-probe credit
                   over the epoch
```

- **Self-route excluded.** Self-route settles at $0 today, but a provider can be
  its own consumer through a second account; jobs where the consumer account ==
  the provider's account never count.
- **Probe credits excluded.** Synthetic probes (§6) may pay a tiny real amount
  for indistinguishability; those credits are flagged and excluded from both the
  reduction and any revenue metric.

---

## 6. Eligibility gate (anti-gaming)

A machine accrues a floor for the epoch **only while all of these hold**. Floor
without these is $0 — unproven capacity earns nothing (it must not dilute honest
providers).

1. **Attested** — trust ∈ {`hardware`, `self_signed`} ≥ `MIN_TRUST`.
2. **Memory verified** — serial→model lookup **and** a tier-sized correctness
   probe confirm the machine can hold the tier it's being paid for.
3. **Online ≥ 90%** of the epoch (else `avail` ramps the floor down).
4. **Healthy** — memory pressure < 0.8, thermal ≠ critical, and the advertised
   model is actually loaded for routing.
5. **Proven work** — in a rolling window, **either** passed ≥1 coordinator
   correctness-probe **or** served ≥1 coordinator-dispatched, other-account,
   billed job. Self-route and self-reported counters do not qualify.

### Three code realities that gate shipping

These were verified against the coordinator source. The reward is farmable until
each is fixed:

- **MDM `SecurityInfo` carries the serial number but *not* memory size**
  (`coordinator/mdm/mdm.go`). `MemoryGB` arrives only via the self-reported
  heartbeat. → A 16GB Air can claim 512GB and bank $40. **Fix: serial→model
  lookup + tier-sized probe; never raise a floor from a self-reported spec.**
- **No probe code exists.** "Served work" is provider-reported (`requests_served`).
  **Fix: coordinator runs known-answer probes** — encrypt to the provider's
  X25519 key like a real consumer, temp=0 on a pinned model + weight-hash, check
  the SE-signed `ResponseHash` against the precomputed expected hash. Make probes
  indistinguishable (occasionally pay them; rotate consumer keys; fire at random
  times within the epoch).
- **Self-route settles at $0 and credits success unconditionally**
  (`coordinator/api/consumer.go`, `coordinator/api/provider.go`). **Fix: count
  only coordinator-dispatched, other-account, billed jobs toward the work gate.**

### Concentration — per-machine, no per-account cap (default)

Base rewards are paid **per machine, not per account**: an operator running N
real, attested, serving Macs contributes N machines of capacity and earns N
floors. We deliberately do **not** cap an account's share by default, because:

- **Attestation is the Sybil defense.** Every machine must be real, attested
  Apple hardware passing the uptime + work/probe gates — you cannot fake
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

The per-provider reduction (§2) already bounds spend in expectation, but a hard
pool cap makes the worst case a number you can pre-commit:

```
network_draw = Σ base_draw_i  ≤  FLOOR_POOL_B
```

| Line | Worst case |
|---|---|
| Draw (`FLOOR_POOL_B`) | **≤ $9,000 / mo** — the board number |
| Probe COGS | ≤ $1,000 / mo |
| Stripe payout fees | ≤ $500 / mo |
| **All-in ceiling `Z`** | **≈ $10,500 / mo** |
| **Today's actual** (≈600 machines) | **≈ $7,600 / mo** — the cap doesn't bind until ~1,000 machines |
| Optional lifetime cap | ~$40,000 → a money-driven end date independent of demand |

**If eligible floors exceed `B`**, allocate floor slots to **protect the
48–96GB workhorse tier** (rank by value-per-floor-dollar + a reserved sub-pool),
**not** biggest-machine-first — otherwise idle 512GB boxes consume the whole pool
and the workhorse tier the marketing is written for gets $0.

### Honest note on "self-liquidating"

The per-machine draw extinguishes when `earned ≥ floor`, but that crossover is
**far** above alpha demand. A 64GB Max at ~40 tok/s would need ~105% single-stream
(≈ 35% sustained-batched) utilization to gross its own $18. So **plan this as a
flat ~$8k/mo retention line for many months**, not a fast taper. It is real burn
— affordable on a seed runway, correctly understood as supply-side CAC. The
reduction guarantees it *ends* eventually; it does not make it cheap *now*.

---

## 8. Settlement & restart-safety

- **Per-token earnings** settle live per-job, as today (`CreditProviderAccount`).
- **The base draw** settles once at epoch close: one **idempotent** ledger entry
  per machine, entry type `provider_floor_draw`, unique key
  `(provider_key, epoch_id)`, `ON CONFLICT DO NOTHING`. The provider sees a
  combined "earned + floor top-up" number.
- **Uptime / `avail`** computed from durable `provider_sessions` intervals
  (union overlapping rows per machine — blue-green deploys leave two open rows);
  an open session accrues only to `min(epoch_end, last_seen + 90s grace)`.
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
| Relationship to earnings | additive (`base + usage`) | **reduced by earnings** (`max(earned, floor)`, or `k`-tapered) |
| Total cost | unbounded (`rate × fleet × time`) | **bounded** by `FLOOR_POOL_B`; self-liquidating |
| Valuation | `memBase + bwBonus` (sum) on **self-reported** specs | memory-tier floor on **verified** memory |
| Work proof | "warm model loaded" (idle-farmable) | probe / dispatched billed job; self-route excluded |
| Durability | in-memory, lost every deploy | durable `provider_sessions` + idempotent settlement |
| Demand coupling | none | per-provider reduction + fleet sunset taper |

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
  rank, and the `earned + top-up` breakdown in the dashboard.

---

## 11. Phased rollout

**Phase 0 — bounded floor, honest gate, restart-safe (~3 wks).** Floor table +
`k=1` reduction; eligibility gates 1, 3, 4, and the *billed-job* half of gate 5
(cheap — no new schema); `UNIQUE(job_id)` + idempotent `provider_floor_draw`
settlement from `provider_sessions`; slot allocation protecting the workhorse
tier; per-machine payout (per-account cap off by default). Idlers and self-dealers earn nothing
from day one. Test live-isolated against throwaway Postgres (double-credit,
blue-green double-open, partial-settlement Σ==pool, empty-fleet no-NaN,
pre-attestation unpaid).

**Phase 1 — verified capacity + probes (~2 wks).** serial→model memory
verification; coordinator correctness-probes (gate 2 + probe half of gate 5).

**Phase 2 — tapers + sunset.** Per-network revenue taper + calendar glide;
per-machine 30%-drop cliff guard; published off-ramp condition.

**Phase 3 — fee handoff.** When the platform fee turns on, fund any residual
incentive from the fee pool; sunset the cold-start floor per §4b.

---

## 12. Open decisions

1. **`k`** — ship `k = 1` (pure floor, cheapest) or `k ≈ 0.5–0.8` (preserve ramp
   incentive, costs more)? Recommendation: **`k = 1`**.
2. **`FLOOR_POOL_B` = $9,000/mo and all-in `Z` ≈ $10,500/mo** — approve as the
   pre-committed ceiling? And a `~$40k` lifetime cap?
3. **48GB tier** — keep at $16 marketed as "Netflix with ads," or raise to ≥$18
   to make it honestly Standard (+~$1–2k/mo worst case)?
4. **Epoch length** — monthly (matches the "Netflix" framing) with a live
   dashboard estimate, or weekly settlement?
5. **`TARGET_REVENUE` handoff threshold** — set against your demand forecast
   (proposed ≈ 3× pool).
6. **Entry tiers (decided)** — 24GB ($10) and 32GB ($12) now earn a floor to
   incentivize the common mid-range Macs (they can serve the 20B baseline +
   specialist STT/embeddings work, and the fleet skews into this range). They
   earn only while serving (work gate). Open sub-question: extend a floor to
   16GB for specialist-only work, or keep 24GB as the threshold?
