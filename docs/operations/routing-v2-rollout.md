# Routing v2 — Staged Rollout Runbook

How to deploy the `routing-v2` coordinator branch to production **without breaking
prod**. Routing v2 flips many admission/routing behaviours on at once (most are
default-ON in the branch), so this runbook stages them with env flags, keeps a
single kill-switch, and gates the security-sensitive pieces behind sign-off.

- Design doc (source of truth): [`../architecture/routing-v2.md`](../architecture/routing-v2.md)
- Attestation churn design: [`../architecture/routing-v2-attestation-churn.md`](../architecture/routing-v2-attestation-churn.md)
- Base deploy mechanics (EigenCloud/GCP, build, env injection): [`coordinator-deploy.md`](coordinator-deploy.md)

> **No deploys by the agent.** A human applies every stage (EigenCloud/GCP).
> This runbook only prescribes the sequence, flags, and checks.

---

## Summary — what routing-v2 changes vs `master`

Today prod 429s **~71%** of `chat/completions` (9,804×200 vs 23,837×429 over a
~67-min window); **97.9%** of rejects are `ttft_too_slow`, **100%** had
`could_have_served=true`, `machine_busy`=0, while token budget is 99.94% free
([`../architecture/routing-v2.md`](../architecture/routing-v2.md) §1). It is not a
capacity problem — it is over-rejection plus locked-out trusted machines.

Routing v2 (stacked on PR #381) changes, relative to `master`:

| Change | Workstream | Where |
|---|---|---|
| **Soft TTFT gate** — slow estimated TTFT becomes a routing *preference*, not a pre-dispatch 429 (kill-switch restores hard gate) | W0 / PR #381 | `coordinator/cmd/coordinator/main.go:296-304`, `SetTTFTHardReject` |
| **Prefill ×12** fallback ratio (was ×4) when no measured prefill rate | W0 / PR #381 | `coordinator/registry/scheduler.go:1106` (`defaultPrefillToDecodeRatio = 12.0`) |
| **Decode-floor quality bar** — per-request sustained-decode floor (default 15 tok/s), soft preference, never fails closed | W2 | `coordinator/cmd/coordinator/main.go:318-332`, `SetMinDecodeTPS` |
| **Queue-before-shed** — capacity-rejects route into the dispatch queue instead of an immediate 429 | W3 | `coordinator/api/cold_dispatch.go:20-54` |
| **Cold-dispatch spill** — `no_provider` requests spill to a warming idle on-disk provider via model-swap | W3 | `coordinator/api/cold_dispatch.go:26-61` |
| **Warm-pool rebuild** — Little's-Law target, all-signal pressure (incl. preflight near-misses + shed), demand-scaled faster ramp | W4 | `coordinator/registry/warm_pool_target.go`, config `coordinator/registry/config.go:82-106` |
| **Attestation churn fixes** — verify in read-loop delivery path; freshness 6m→16m; expiry/timeout 60/90s→300s | W5b | `coordinator/api/provider.go:461-478`, `coordinator/registry/scheduler.go:37`, `coordinator/apns/attestor.go:73` |
| **Throughput anomaly detector** — flags models decoding below their active-param/hardware class (the gemma-dense bug) | W8 | `coordinator/api/throughput_anomaly.go`, `coordinator/registry/throughput_anomaly.go` |
| **Trace-driven sim harness** — replays the real prod trace against the real scheduler in CI (the safety net) | W7 | `coordinator/registry/routingsim/` |

One line: **serve on the fastest warm provider that stays above the quality
floor; else grow warm capacity; else queue; shed only when truly saturated.**

---

## Prerequisites

- [ ] `routing-v2` builds and unit tests pass:
  ```bash
  make coordinator-test
  make coordinator-build
  ```
- [ ] **Sim harness green** (W7 — no routing change ships without it):
  ```bash
  go test ./coordinator/registry/routingsim/... -run TestRoutingSim -v
  ```
  Expected: `TestRoutingSimCalibration`, `TestRoutingSimPrefillRatio12MovesCliff`,
  `TestRoutingSimSoftGateServesEverything` pass
  ([`coordinator/registry/routingsim/routingsim_test.go:42,72,99`](../../coordinator/registry/routingsim/routingsim_test.go)).
- [ ] `ecloud` CLI access (prod) and `gcloud` access to `sepolia-ai` (dev), per
  [`coordinator-deploy.md`](coordinator-deploy.md).
- [ ] Datadog access to watch `routing.*`, `code_attest_total`, and provider
  capacity metrics; and admin-key access for `/v1/admin/*`.
- [ ] **Security sign-off obtained** for the attestation stage (see
  [Security review checklist](#security-review-checklist)) — required before
  Stage 5 in prod.
- [ ] Provider-release plan for W1 telemetry (see [Sync points](#sync-points)).

> **When flags take effect.** The `main.go` flags (`TTFT_HARD_REJECT`,
> `PREFILL_DECODE_RATIO`, `MIN_DECODE_TPS`, `APNS_MODE`) and the warm-pool config
> (`registry.ReadConfig`, [`coordinator/registry/config.go:79`](../../coordinator/registry/config.go))
> are read **once at process start** — each change needs a coordinator
> restart/redeploy. `EIGENINFERENCE_QUEUE_BEFORE_SHED` and
> `EIGENINFERENCE_COLD_DISPATCH` are read **live per request**
> ([`coordinator/api/cold_dispatch.go:13-18`](../../coordinator/api/cold_dispatch.go)),
> but on EigenCloud/GCP an env change is a redeploy anyway. Treat every stage as
> "set env → redeploy → verify".

---

## Flag matrix

All defaults below are **verified against the code on this branch**. Boolean
flags parsed by `env.EnvBool` accept `strconv.ParseBool` values; the two
cold-dispatch flags use their own parser that disables only on
`0`/`false`/`no`/`off`
([`coordinator/api/cold_dispatch.go:41-48`](../../coordinator/api/cold_dispatch.go)).

### Core routing (`coordinator/cmd/coordinator/main.go`)

| Flag | Default | What it does | Blast radius | Disable / revert |
|---|---|---|---|---|
| `EIGENINFERENCE_TTFT_HARD_REJECT` | `false` (soft) | `true` restores the legacy **hard 429** when estimated TTFT exceeds the `5s+1ms/tok` deadline (`main.go:301`) | **Global kill-switch** — reverts the headline behaviour to `master` | This *is* the revert: set `=true` |
| `EIGENINFERENCE_PREFILL_DECODE_RATIO` | `12` (`scheduler.go:1106`) | Prefill-TPS = decode×ratio fallback when no measured prefill rate (`main.go:309`) | Changes TTFT estimate for unmeasured providers | Set `=4` for `master` behaviour |
| `EIGENINFERENCE_MIN_DECODE_TPS` | `15` (quality bar **ON**) | Per-request sustained-decode floor; soft preference, never fails closed (`main.go:318-332`) | Quality of admitted streams. **Keep ON when opening floodgates.** | `0` disables the floor |

### Queue / cold-dispatch (`coordinator/api/cold_dispatch.go`)

| Flag | Default | What it does | Blast radius | Disable |
|---|---|---|---|---|
| `EIGENINFERENCE_QUEUE_BEFORE_SHED` | `true` | `machine_busy` preflight 429s route into dispatch+queue instead (`cold_dispatch.go:20-25,52`) | Queue depth, tail latency | `=false` |
| `EIGENINFERENCE_COLD_DISPATCH` | `true` | Spill `no_provider` to a warming idle on-disk provider; kick model-swap on enqueue (`cold_dispatch.go:26-30,59`) | Provider model-load churn / memory | `=false` |

### Warm pool (`coordinator/registry/config.go:82-106`, prefix `EIGENINFERENCE_WARM_POOL_`)

| Flag (suffix) | Default | What it does | Disable / safe value |
|---|---|---|---|
| `_ENABLED` | `true` | Master switch for the warm-pool controller | `=false` |
| `_OBSERVE_ONLY` | `false` | Dry-run: compute targets, issue **no** loads | `=true` (safe observe) |
| `_INTERVAL` | `10s` | Controller tick | larger = slower |
| `_MIN_DWELL` | `5m` | Min time warm before eviction | — |
| `_QUEUE_AGE_THRESHOLD` | `0` | Queue-age pressure trigger | — |
| `_CAPACITY_REJECT_THRESHOLD` | `1` | Capacity-reject pressure trigger | higher = less eager |
| `_WARM_SATURATION_THRESHOLD` | `0.8` | Warm-fraction saturation trigger | — |
| `_TTFT_MISS_THRESHOLD` | `1` | TTFT-miss pressure trigger | higher = less eager |
| `_SPECULATIVE_START_THRESHOLD` | `2` | Speculative-start pressure trigger | — |
| `_SPECULATIVE_WIN_THRESHOLD` | `1` | Speculative-win pressure trigger | — |
| `_COLD_DISPATCH_THRESHOLD` | `1` | Cold-dispatch pressure trigger | — |
| `_LOAD_DURATION_THRESHOLD` | `20s` | Cold-start cost gate | — |
| `_DECODE_FLOOR_TPS` | `15` | Floor used to derive per-provider quality concurrency for the target | `0` disables the quality constraint |
| `_BURST_BUFFER` | `1` | Spare warm providers above demand target | `0` = tightest |
| `_FALLBACK_QUALITY_CONCURRENCY` | `4` | Per-provider concurrency when rates unknown | — |
| `_ASSUMED_PROMPT_TOKENS` | `512` | Representative request for E[S] | — |
| `_ASSUMED_COMPLETION_TOKENS` | `256` | Representative request for E[S] | — |
| `_MAX_LOADS_PER_TICK` | `4` | Baseline per-tick load burst | `1` mimics the old slow ramp |
| `_MAX_LOADS_PER_TICK_CEILING` | `16` | Hard per-tick cap after demand scaling | lower = gentler |
| `_RAMP_GAP_FRACTION` | `0.5` | Scales burst with remaining target gap | `0` = no scaling |
| `_MAX_GLOBAL_PENDING_LOADS` | `16` | Fleet-wide in-flight load cap | `4` mimics the old cap |

### Throughput anomaly detector (`coordinator/api/throughput_anomaly.go`, `coordinator/registry/throughput_anomaly.go`)

| Flag | Default | What it does | Disable |
|---|---|---|---|
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_INTERVAL` | `5m` (`throughput_anomaly.go:29`) | Fleet sweep cadence | larger = quieter |
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_RATIO` | `0.35` (`DefaultAnomalyRatioThreshold`, `registry/throughput_anomaly.go:59`) | observed/expected below this ⇒ flag | lower = quieter |
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_MIN_SAMPLES` | `3` (`DefaultAnomalyMinSamples`) | min samples before flagging | higher = quieter |
| `EIGENINFERENCE_THROUGHPUT_ANOMALY_EFFICIENCY` | `0.80` (`DefaultDecodeEfficiency`) | fraction of peak bandwidth assumed sustained | — |

Detector is **read-only** (metadata + metric only); safe to leave ON.

### Attestation (`coordinator/cmd/coordinator/main.go`)

| Flag | Default | What it does | Blast radius | Disable |
|---|---|---|---|---|
| `APNS_MODE` | `background` | `alert` sends priority-10, non-budget-throttled code-identity pushes — the biggest mover for the locked-out pool (`main.go:659`) | Attestation delivery; **safety-gated** (INV-6) | unset / `background` |

---

## Staged rollout sequence (Steps)

Routing v2 ships with the aggressive behaviours **already default-ON**. Do **not**
deploy the branch to prod with branch defaults in one shot. Stage it: prove on
DEV, then open the floodgates on prod one notch at a time, **keeping the decode
quality bar (`MIN_DECODE_TPS=15`) ON the whole way** and keeping
`EIGENINFERENCE_TTFT_HARD_REJECT` available as the kill-switch.

### Stage 0 — DEV, full branch defaults

Deploy `routing-v2` to dev (GCP) with no flag overrides (everything default-ON).

```bash
# build + sim must already be green (Prerequisites)
# deploy to dev per coordinator-deploy.md (GCP)
```

Run the system E2E suite and watch dev for a representative load window:

```bash
make e2e-integration   # Postgres + Swift provider binary + MLX model required
```

Watch (dev): `/v1/admin/rejections`, `/v1/models/capacity`,
`routing.throughput_anomaly`, `code_attest_total`. Proceed only if `ttft_too_slow`
drops, `machine_busy` stays ~0, and no provider is overloaded.

### Stage 1 — PROD, soft gate + quality bar + measurement; floodgates CLOSED

Deploy the same binary to prod, but hold the load-amplifying behaviours closed and
run the warm-pool controller in dry-run so you get its target signal without loads:

```bash
EIGENINFERENCE_TTFT_HARD_REJECT=false        # kill-switch stays available
EIGENINFERENCE_MIN_DECODE_TPS=15             # quality bar ON (default)
EIGENINFERENCE_QUEUE_BEFORE_SHED=false       # hold closed
EIGENINFERENCE_COLD_DISPATCH=false           # hold closed
EIGENINFERENCE_WARM_POOL_OBSERVE_ONLY=true   # dry-run controller (no loads)
# anomaly detector ON (default); APNS_MODE stays background
```

This already delivers the headline win (stop over-rejecting) at the lowest risk.
Watch: `ttft_too_slow` → near 0; `machine_busy` ~0; per-request decode ≥ 15;
provider load flat.

### Stage 2 — PROD, open queue-before-shed

```bash
EIGENINFERENCE_QUEUE_BEFORE_SHED=true
```

Watch `/v1/models/capacity` `queued` and the queue-timeout 429s. Quality bar stays
ON. Roll back this notch with `=false` if queue depth or tail latency spikes.

### Stage 3 — PROD, warm-pool active with a conservative ramp

Turn the controller from dry-run to active, but cap the ramp to the old slow rate
first:

```bash
EIGENINFERENCE_WARM_POOL_OBSERVE_ONLY=false
EIGENINFERENCE_WARM_POOL_MAX_LOADS_PER_TICK=1
EIGENINFERENCE_WARM_POOL_MAX_LOADS_PER_TICK_CEILING=4
EIGENINFERENCE_WARM_POOL_MAX_GLOBAL_PENDING_LOADS=4
```

Watch provider model-load churn and memory headroom. If stable, raise toward
defaults (`4` / `16` / `16`).

### Stage 4 — PROD, cold-dispatch + full ramp

```bash
EIGENINFERENCE_COLD_DISPATCH=true
EIGENINFERENCE_WARM_POOL_MAX_LOADS_PER_TICK=4
EIGENINFERENCE_WARM_POOL_MAX_LOADS_PER_TICK_CEILING=16
EIGENINFERENCE_WARM_POOL_MAX_GLOBAL_PENDING_LOADS=16
```

Now the fleet serves "all the compute". Quality bar (`15`) is what stops this from
overpacking into degraded streams — confirm no per-request decode dips below 15.

### Stage 5 — PROD, attestation unlock + `APNS_MODE=alert` (security sign-off gated)

The attestation code fixes (W5b) are already in the binary from Stage 1. The
remaining lever is the config flip — apply **only after** the
[Security review checklist](#security-review-checklist) is signed off:

```bash
APNS_MODE=alert
```

Watch `code_attest_total{outcome}`: `timeout` ↓, `attested` ↑, routable pool grows
from ~67/176.

---

## Sync points

- **Provider release for W1 measured telemetry.** The new prefill term only
  becomes *measured* once enough of the fleet ships the provider build that emits
  `observed_prefill_tps` + `model_load_time_ms` on `BackendSlotCapacity`
  ([`../architecture/routing-v2.md`](../architecture/routing-v2.md) W1). Until then
  prefill is the `EIGENINFERENCE_PREFILL_DECODE_RATIO=12` fallback. When that
  provider build is released, bump `LatestProviderVersion`
  ([`coordinator/api/server.go:146`](../../coordinator/api/server.go), currently
  `"0.6.11"`) and keep `scripts/build-bundle.sh` / `scripts/install.sh` in sync
  (AGENTS.md sync points).
- **Telemetry wire types stay aligned** across `coordinator/protocol/telemetry.go`
  (canonical), `provider-swift/Sources/ProviderCore/Telemetry/`, and
  `console-ui/src/lib/telemetry-types.ts`; symmetry tests pin enum casing /
  optional-field omission (AGENTS.md).
- **`APNS_MODE=alert` is a human config flip** (Fix 0) — already wired in
  `main.go:659`; no code change.
- **PR #381 relationship.** `routing-v2` is **stacked on PR #381** — the soft TTFT
  gate + prefill ×12 + kill-switch (W0) are included as the *base* of this branch
  ([`../architecture/routing-v2.md`](../architecture/routing-v2.md) lines 8-9, W0).
  Do not treat #381 as a separate deploy; deploying `routing-v2` ships it.

---

## Verification

Watch these per stage; cite-before numbers are from
[`../architecture/routing-v2.md`](../architecture/routing-v2.md) §1.

| Signal | Endpoint / metric | Before | Expected after |
|---|---|---|---|
| Rejection mix | `GET /v1/admin/rejections` ([`server.go:1752`](../../coordinator/api/server.go); `reasonCode`/`CouldHaveServed` in [`rejection_telemetry.go:20,138`](../../coordinator/api/rejection_telemetry.go)) | ~71% reject; 97.9% `ttft_too_slow`; 100% `could_have_served`; `machine_busy`=0 | `ttft_too_slow` → near 0; `machine_busy` stays ~0 |
| Capacity / queue | `GET /v1/models/capacity` ([`server.go:1620`](../../coordinator/api/server.go)) | budget 99.94% free; 0 queued | `queued` bounded; budget not exhausted |
| Per-request decode | stream tok/s vs floor | n/a | every admitted stream ≥ 15 tok/s |
| Throughput anomaly | `routing.throughput_anomaly{model,chip_family}` ([`throughput_anomaly.go:155-160`](../../coordinator/api/throughput_anomaly.go)) + `/v1/admin/metrics` ([`server.go:1744`](../../coordinator/api/server.go)) | gemma-4-26b-qat-4bit ratio ~0.15 | gemma keeps flagging until W6 MLX fix; gpt-oss (~0.44) not flagged |
| Attestation | `code_attest_total{outcome}` ([`provider.go:478`](../../coordinator/api/provider.go)) | ~67/176 routable; `timeout` high | `timeout` ↓, `attested` ↑, routable pool grows |

If any stage regresses, do **not** advance — roll back that notch (below).

---

## Rollback

Every behaviour is reversible without a rebuild. Roll back the **last notch you
changed** first; escalate to the kill-switch / binary revert if needed.

| Symptom | Roll back |
|---|---|
| Slow streams / over-serving / general regression | **Kill-switch:** `EIGENINFERENCE_TTFT_HARD_REJECT=true` (restores legacy hard gate) |
| Degraded (low tok/s) streams | confirm `EIGENINFERENCE_MIN_DECODE_TPS=15` (not `0`) |
| Queue depth / tail-latency spike | `EIGENINFERENCE_QUEUE_BEFORE_SHED=false` |
| Provider load/memory churn | `EIGENINFERENCE_COLD_DISPATCH=false`; `EIGENINFERENCE_WARM_POOL_OBSERVE_ONLY=true` (or `_ENABLED=false`) |
| Warm-pool load storm | lower `_MAX_LOADS_PER_TICK` / `_MAX_LOADS_PER_TICK_CEILING` / `_MAX_GLOBAL_PENDING_LOADS` (e.g. `1`/`4`/`4`) |
| Attestation problems after Stage 5 | unset `APNS_MODE` (back to `background`) |
| Anomaly metric noise | raise `EIGENINFERENCE_THROUGHPUT_ANOMALY_MIN_SAMPLES` / lower `_RATIO`, or widen `_INTERVAL` |

- **No routing change ships without the `coordinator/registry/routingsim` harness
  green** (W7 safety net,
  [`../architecture/routing-v2.md`](../architecture/routing-v2.md) §10). If a stage
  needs a code change, re-run the harness before redeploy.
- **Full revert (code-level changes, incl. attestation fixes):** roll the
  coordinator back to the previous EigenCloud revision per
  [`coordinator-deploy.md`](coordinator-deploy.md) → Rollback (EigenCloud keeps the
  previous revision warm during blue-green).

---

## Security review checklist

The attestation changes (W5b) are **code-level and ship in the binary from Stage 1**;
`APNS_MODE=alert` ships in Stage 5. All items below **need sign-off before prod**.

- [ ] **Fix 1 — verification moved to the read-loop delivery path.** Round-trip is
  decoupled from the 90s connection-blocking wait; verification moves *byte-for-byte*
  (no new attest path), and `CodeAttested` is set under `provider.Mu()`
  ([`coordinator/api/provider.go:461-478`](../../coordinator/api/provider.go);
  [`../architecture/routing-v2-attestation-churn.md`](../architecture/routing-v2-attestation-churn.md)
  Fix 1). Confirm fail-closed code identity (nonce==pushed AND `Sign_SE` verifies
  against the registration-bound SE key) is preserved.
- [ ] **Freshness 6m → 16m.** `challengeFreshnessMaxAge`
  ([`coordinator/registry/scheduler.go:37`](../../coordinator/registry/scheduler.go))
  is an **SE-liveness** staleness bound, **not** code identity — a single revertable
  const. Confirm the liveness trade is acceptable.
- [ ] **Timeout ordering (Fix 5).** `CodeAttestResponseTimeout` 90s→300s
  ([`coordinator/api/provider.go:468`](../../coordinator/api/provider.go)) and
  `challengeExpirySeconds` 60s→300s
  ([`coordinator/apns/attestor.go:73`](../../coordinator/apns/attestor.go)) — expiry
  ≥ wait now, killing the 60s<90s inversion.
- [ ] **W5 Fix 2 (deferred) does not weaken trust.** When it lands: the APNs token
  in the heartbeat **does NOT grant trust**, and reuse persistence is
  **version-gated + windowed** (same 30-min window + version gate)
  ([`../architecture/routing-v2-attestation-churn.md`](../architecture/routing-v2-attestation-churn.md)
  Fix 2). Re-review before that change ships.
- [ ] **INV-6 — alert-mode safety.** `APNS_MODE=alert` is safe only while the
  provider never requests `UNUserNotificationCenter` auth. Confirm the CI assertion
  guarding this is present/green before Stage 5.

---

## Open items

- **gemma MLX 4-bit decode fix (W6)** — owned by a **separate job**. Root cause is
  the MLX 4-bit `gatherQuantizedMM` small-batch path (gemma decodes at ~21 tok/s ≈
  dense-26B bandwidth vs ~142 sparse expectation; gemma is ~63% of demand, ~3×
  recoverable). The anomaly detector will **keep flagging gemma** until this lands
  ([`../architecture/routing-v2.md`](../architecture/routing-v2.md) §1, W6).
- **`make e2e-integration` run** — requires Postgres + the Swift provider binary +
  an MLX model downloaded; run in Stage 0 (dev) before prod.
- **W1 deferred sub-fields** — `observed_ttft_ms` and `decode_knee` are deferred to a
  follow-up; until then the per-request decode projection unwinds measured decode
  rather than reading a measured knee
  ([`../architecture/routing-v2.md`](../architecture/routing-v2.md) W1, §11).
- **W8 decode-class table coverage** — `ModelDecodeClasses` in
  `coordinator/registry/throughput_anomaly.go` keys on the served model id
  (`gpt-oss-20b`, `gemma-4-26b-qat-4bit` today, matching what the prod fleet
  advertises via `/v1/models`). It is fail-safe on unknown ids — an id absent from
  the table is **not evaluated** (a missed detection, never a false alarm) — so a
  future rebuild under a different id (e.g. an 8-bit `mlx-community/...` variant)
  silently falls through until its id + active-param count is added. Add a table
  entry per new served build id (Codex PR #383 follow-up).
- **W3 shape-aware cold-load planning** — the cold-load warm check
  (`hasWarmProviderLocked`) and planner (`bestModelLoadProviderLocked` /
  `planModelLoadActions` in `coordinator/registry/registry.go`) are MODEL-keyed,
  not request-shape-keyed. So in a fleet that is shape-*heterogeneous* for the same
  model (a provider that serves it text-only while the request `requiresVision`, a
  tool-incapable build, or an allowed-serial restriction), a warm but wrong-shape
  provider can make `ColdSpillProviders` short-circuit to 0 and/or make the planner
  warm a provider the request can never drain to — so the request follows the
  pre-W3 preflight path / waits out the queue timeout instead of warming the
  *eligible* cold provider. Non-regression (this is pre-existing model-only
  planning; W3 does not make it worse) and rare for the current models
  (vision/tools capability is model-uniform; the public cold-spill path carries no
  serial constraint). A complete fix threads the queued request's traits/vision/
  serial through the queue→planner interface so cold loads target a provider that
  can actually serve the queued shape (Codex PR #383 follow-up).
