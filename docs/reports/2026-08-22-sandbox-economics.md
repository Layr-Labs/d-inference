# Sandbox economics and pricing

Status: **proposed model; rate card requires measured alpha data**

Date: 2026-08-22

Parent plan: [Darkbloom sandbox platform plan](2026-08-22-sandbox-platform-plan.md)

User experience: [Provider and developer experience](2026-08-22-sandbox-user-experience.md)

## 1. Bottom line

Darkbloom can compete with E2B's public CPU/RAM rates on hardware economics.
Electricity is not the limiting cost. At a modeled 90 W active draw and the May
2026 U.S. average commercial electricity price, power is about **$0.012 per
host-hour**. Hardware amortization, utilization, provider reliability, support,
and startup latency matter much more.

A representative 10-vCPU/48-GiB allocatable Mac host produces **$1.2816 per
fully allocated hour** at E2B's published resource rates. Under the disclosed
sample assumptions below, the host costs **$0.18–$0.43 per billable host-hour**
at 75%–25% utilization. At 50% utilization the modeled cost is **$0.242/hour**.

That does not mean Darkbloom should sell macOS at Linux parity. macOS supply,
chip selection, GUI automation, and exclusive-host guarantees are
differentiated. The recommended launch price is:

- Linux at the E2B resource benchmark;
- standard macOS at **1.5×** the resource benchmark;
- computer-use macOS at **1.875×** before video egress;
- exact-chip selection as a visible supply premium; and
- timing-sensitive GPU/CPU as a whole-host quote, never a fictional fractional
  GPU reservation.

There is no 24-hour compute floor in this model. Stopped sandboxes incur
retained-storage charges only.

## 2. External price benchmark

As checked on 2026-08-22, E2B publishes:

| Resource | Per second | Per hour |
|---|---:|---:|
| vCPU | $0.000014 | **$0.0504** |
| RAM GiB | $0.0000045 | **$0.0162** |

Sources:

- [E2B sandbox price calculation](https://e2b.dev/docs/faq/calculate-sandbox-price)
- [E2B billing](https://e2b.dev/docs/billing)
- [E2B pricing](https://www.e2b.dev/pricing)

E2B charges while a sandbox is running and includes a plan-dependent disk
allowance. Its Pro plan also has a fixed subscription fee. The comparison below
uses only public usage rates because Darkbloom's differentiated Mac product
should not depend on a subscription floor to make a job economical.

A vCPU is not a standardized unit of performance across Apple performance and
efficiency cores, cloud x86, and oversubscribed hosts. E2B is a price benchmark,
not a claim of equal per-vCPU speed. Darkbloom must publish chip and benchmark
class with each quote.

## 3. First-principles host-cost model

For one host:

```text
active_host_cost_per_hour =
    (purchase_price - salvage_value)
      / (economic_life_hours × billable_utilization)
  + active_power_kW × electricity_price_per_kWh
  + network_facility_and_wear_per_active_hour
  + expected_failure_and_support_cost_per_active_hour
```

Definitions:

- **Billable utilization** is the fraction of calendar hours that produce
  settled compute revenue. It is not CPU utilization inside a running VM.
- **Economic life** ends when the machine is replaced for reliability or
  product competitiveness, even if it still boots.
- **Host cost** must be compared with the full CPU+RAM bundle. Assigning every
  dollar to CPU and then charging memory again double-counts cost.
- Payment processing, control-plane compute, taxes, refunds, fraud, support,
  and corporate overhead belong in platform margin, not in electricity.

## 4. Worked Mac example

This is a sensitivity model, not a hardware quote.

| Input | Assumption | Basis |
|---|---:|---|
| Host purchase price | $2,500 | Replace with actual delivered price |
| Salvage value | $0 | Conservative |
| Economic life | 3 years / 26,280 hours | Planning assumption |
| Allocatable vCPU | 10 | Leaves 2–4 physical cores for host duties depending on SKU |
| Allocatable memory | 48 GiB | Leaves 16 GiB on a 64-GiB host |
| Average active draw | 90 W | Modeled between Apple's 5 W idle and 140 W maximum data |
| Electricity | $0.1354/kWh | U.S. commercial average, May 2026 |
| Network/facility/SSD/failure placeholder | $0.04/active hour | Must be replaced by observed provider cost |

Apple publishes 5 W idle and 140 W maximum power for a 64-GiB M4 Pro Mac mini
configuration. The 90 W row is deliberately a model input, not a claim that
every workload consumes 90 W. Source:
[Apple Mac mini power consumption](https://support.apple.com/en-us/103253).

The U.S. Energy Information Administration reports a May 2026 average
commercial price of 13.54 cents/kWh. Source:
[EIA Electricity Monthly Update](https://www.eia.gov/electricity/monthly/update/end-use.php).

### 4.1 Cost sensitivity

| Billable utilization | Amortization per active hour | Power | Other placeholder | Total active host cost |
|---:|---:|---:|---:|---:|
| 25% | $0.3805 | $0.0122 | $0.0400 | **$0.4327** |
| 50% | $0.1903 | $0.0122 | $0.0400 | **$0.2424** |
| 75% | $0.1268 | $0.0122 | $0.0400 | **$0.1790** |

If the full host cost were divided only by ten allocatable vCPUs, it would be
1.79–4.33 cents per vCPU-hour across this utilization range. That number is
useful as an upper bound on CPU cost but is not a valid standalone rate because
the same machine also sells memory.

### 4.2 Revenue at the E2B benchmark

```text
10 vCPU × $0.0504/hour       = $0.5040/hour
48 GiB × $0.0162/GiB-hour   = $0.7776/hour
------------------------------------------------
full host resource revenue  = $1.2816/hour
```

| Billable utilization | Modeled cost | Benchmark revenue | Gross headroom before platform overhead |
|---:|---:|---:|---:|
| 25% | $0.4327 | $1.2816 | **66.2%** |
| 50% | $0.2424 | $1.2816 | **81.1%** |
| 75% | $0.1790 | $1.2816 | **86.0%** |

The headroom is not net profit. It must fund:

- provider payout and platform margin;
- unused resource fragments between sandbox shapes;
- failed boots and non-billable preparation;
- image distribution and snapshot transfer;
- relays/TURN and internet egress;
- Stripe and fraud loss;
- support and provider operations;
- warranty failures and spare capacity; and
- taxes and legal/compliance work.

Even after those deductions, electricity is visibly not the economic blocker.

### 4.3 Provider break-even illustration

If a provider receives 70% of E2B-benchmark resource revenue:

```text
provider revenue at full allocation = $1.2816 × 70% = $0.89712/active hour
```

With the same $2,500 host, three-year life, 90 W power, and $0.04/hour
placeholder, the modeled capital break-even utilization is about **11.3%**.
This is a sensitivity result, not a promised return. A provider with expensive
power, managed hosting, financing, labor, poor reliability, or a shorter
replacement cycle has a higher threshold.

## 5. Recommended launch rate card

Keep one composable formula:

```text
charge =
  runtime_seconds × (
      vCPU_count × vCPU_rate
    + memory_GiB × memory_rate
    + OS_scarcity_premium
    + chip_premium
    + computer_use_premium
    + exclusive_host_premium
  )
  + successful_boot_fee
  + retained_byte_seconds × storage_rate
  + metered_network_egress
```

All dimensions appear in the quote. No multiplier is hidden after execution.

### 5.1 Base resource rates

| Product | vCPU-hour | GiB-hour | Rationale |
|---|---:|---:|---|
| Linux Sandbox | $0.0504 | $0.0162 | Match E2B's public usage benchmark |
| macOS Sandbox | Base × 1.5 total | Base × 1.5 total | Scarcity and Apple-specific capability |
| macOS Computer | Base × 1.875 total | Base × 1.875 total | macOS 1.5× plus 25% GUI/driver capacity premium |

The implementation should store separate base and premium line items even when
the launch UI presents a multiplier. This allows chip and computer-use supply
to move independently later.

### 5.2 Example hourly prices

| Shape | Base CPU+RAM | Linux | macOS 1.5× | macOS Computer 1.875× |
|---|---:|---:|---:|---:|
| 4 vCPU / 8 GiB | $0.3312 | $0.3312 | **$0.4968** | **$0.6210** |
| 6 vCPU / 16 GiB | $0.5616 | $0.5616 | **$0.8424** | **$1.0530** |
| 8 vCPU / 32 GiB | $0.9216 | $0.9216 | **$1.3824** | **$1.7280** |
| 10 vCPU / 48 GiB host | $1.2816 | $1.2816 | **$1.9224** | **$2.4030** |

A 15-minute 4-vCPU/8-GiB macOS command has a maximum compute hold of
**$0.1242** before any successful boot fee or network egress.

### 5.3 Exact-chip premium

Exact-chip selection is a supply constraint, not a cosmetic label.

Recommended alpha policy:

- no premium for a portable minimum benchmark class;
- 10–40% of base CPU+RAM price for an exact scarce chip, bounded by the
  provider's posted offer and displayed before creation; and
- no claim or price for a chip that has not passed Darkbloom's benchmark and
  attestation checks.

An `M5` request is therefore a hard filter with an explicit quote, not an
assumption about current availability.

### 5.4 Exclusive host and GPU

Virtualization.framework does not expose fractional GPU partitioning or vCPU
core pinning. Price timing-sensitive work as a host reservation:

```text
exclusive price =
  max(full allocatable host resource quote, provider exclusive floor)
  + 20% exclusivity premium
```

The host must drain inference and every other sandbox before the reservation
starts. The quote names the physical chip and benchmark result. "20 GPU cores"
describes hardware; it does not promise 20 isolated guest GPU cores.

Do not offer an SLA for guest Metal compute until the specific application is
benchmarked. Apple's macOS guest uses a paravirtualized graphics path rather
than true device passthrough, and exposed capabilities can differ from the host.

### 5.5 Boot fee

Preparation consumes provider resources before compute billing begins. Use a
small successful boot fee only if alpha measurements show it is necessary:

- warm boot: zero or minimal fee;
- cold base-image download: developer sees the fee in advance;
- failed prepare/boot: zero charge; and
- provider payout only after guest readiness.

Do not recover failed-start cost through an opaque minimum command charge.

## 6. Storage economics

The developer selects a 25- or 50-GiB logical quota. Sparse unused bytes cost
nothing and should not be billed as if written.

Recommended alpha storage policy:

- base images: free to the developer and not counted as tenant storage;
- workspace while compute is running: included up to the selected quota;
- stopped/retained workspace: **$0.08 per actual encrypted GiB-month**;
- transfer/replication: included within a published monthly allowance, then
  passed through; and
- deletion: billing ends when key wrappers are tombstoned, not when background
  ciphertext reclamation finishes.

At that rate:

| Actual retained bytes | Monthly charge |
|---:|---:|
| 5 GiB | $0.40 |
| 25 GiB | $2.00 |
| 50 GiB | $4.00 |

The rate is intentionally above raw SSD depreciation because it also funds
reservation, verification, encrypted snapshot movement, host churn, and a
portable recovery copy.

For comparison, a hypothetical $200 2-TB SSD amortized over 36 months at 50%
sold utilization costs roughly **$0.0056/GiB-month** before writes, failures,
replication, transfer, and operations. Raw media is not the expensive part;
durability and availability are.

Storage payout should use verified unique byte-seconds:

```text
provider_storage_payout =
  verified_unique_encrypted_bytes
  × retained_seconds
  × provider_storage_rate
```

Do not pay for logical sparse size, duplicate chunks, base images, orphaned
ciphertext without a live wrapper, or bytes beyond the provider's accepted
retention reservation.

## 7. Platform and provider split

The inference alpha's zero platform fee in
`coordinator/payments/pricing.go` should not leak into sandbox pricing.
Sandboxes have different capital, relay, support, and failure costs.

Recommended starting split:

| Charge | Provider | Darkbloom before external costs |
|---|---:|---:|
| Compute and OS/chip/computer premium | 70% | 30% |
| Successful boot fee | 80% | 20% |
| Retained storage | 70% | 30% |
| Network egress | Pass-through net of processing | No margin initially |

Use per-provider overrides to bootstrap scarce supply, but keep the developer
rate deterministic for an accepted quote. Providers set a reserve price;
developers do not participate in a live auction.

At the E2B benchmark, 70% gives the representative fully allocated host
$0.8971/hour. At the proposed 1.5× macOS rate it gives
**$1.3457/hour**. The provider's statement must show gross charge, platform
fee, refunds, and net payout.

## 8. Utilization strategy

The largest economic risk is idle capacity, not electricity. Improve
utilization in this order:

1. keep the global macOS launch cap at two until demand is observed;
2. prebuild a small set of fixed shapes to reduce memory fragmentation;
3. prefer a verified sticky host only after hard eligibility checks;
4. let inference and sandbox workloads coexist only after measured isolation;
5. use provider posted availability windows;
6. offer stopped storage without holding compute capacity; and
7. add hosts only when queue latency and rejected demand justify them.

Do not discount below cost merely to fill a machine. A provider reserve price
and platform minimum margin are both hard scheduling filters.

## 9. Linux position

Commodity Linux is a tighter market than macOS. Darkbloom can match E2B if
providers have low-cost or already-owned hardware and sufficient utilization,
but price alone is not a durable advantage.

Launch Linux at the public E2B resource rates and compete on:

- one API across Linux and macOS;
- chip/host selection;
- provider marketplace supply;
- encrypted sticky state;
- explicit exclusive-host reservations; and
- integrated computer-use products.

Firecracker's low per-VM overhead improves density, but the production host
still needs memory reserves, a jailer, kernels, storage, networking, and spare
capacity. Do not put Firecracker's published sub-5-MiB VMM overhead into a
pricing model as if it were total sandbox memory.

## 10. Metering rules

Compute billing starts at `ready`, not when image download begins. It stops at
the earliest of:

- durable `stopped`;
- `deleted`;
- command/sandbox deadline;
- coordinator loss-of-heartbeat cutoff; or
- terminal host failure.

Meter in bounded slices, for example 30 seconds, but price to the exact observed
millisecond or second using integer arithmetic. The slice is a persistence and
recovery unit, not a rounding license.

The coordinator places a maximum hold and settles:

```text
settlement =
  min(observed_billable_duration, quoted_maximum_duration)
  × immutable_quote_rates
  + accepted_storage
  + accepted_egress
```

Unused hold is released. Duplicate usage heartbeats and coordinator restarts
cannot duplicate a settlement. No meter may continue indefinitely because a
provider omitted a stop event.

## 11. Measurements required before locking prices

The Phase 0 proof must report:

- delivered hardware price, warranty, expected replacement life, and salvage;
- idle, one-VM, two-VM, build, GUI, and exclusive-host wall power;
- host CPU/memory reserves;
- cold and warm boot p50/p95/p99;
- failed-boot rate and retry cost;
- shape-specific fragmentation;
- snapshot read/write amplification and SSD wear;
- image/snapshot transfer and TURN egress;
- provider and coordinator support burden;
- uptime, command success, and checkpoint success;
- actual billable utilization; and
- developer willingness to pay by product/chip.

Update the sample model with those measurements. If measured 25th-percentile
provider margin is negative after platform fees and failure cost, raise the
rate or reject that offer; do not rely on fleet averages to hide an
uneconomical provider.

## 12. Go/no-go economics

Proceed from private alpha only if all are true:

1. standard macOS sells with positive provider and platform contribution at
   25% billable utilization;
2. failed starts and refunds consume less than 10% of gross sandbox revenue;
3. sticky retention saves more startup cost/latency than its transfer and
   storage expense;
4. the two-slot cap has enough observed demand to justify another host;
5. developer quotes remain competitive with E2B for Linux and visibly valuable
   for macOS; and
6. exclusive-host pricing covers the full displaced inference and sandbox
   opportunity cost.

The economic thesis is therefore testable: Darkbloom does not need cheaper
electricity than cloud vendors. It needs adequate utilization, reliable hosts,
honest resource guarantees, and a premium for capabilities E2B does not
currently expose.

