# Coordinator performance program — 2026-09-02

Status: in progress (branch `worktree-bridge-cse_01TuyfD42fkRyG4ZqSTmeN4U`, based on master `a1f51ea4c`).

This report is the first-principles pass over every coordinator operation with a
measurable cost: the inference hot path (auth → parse → admit → route → dispatch →
stream → settle), the fleet-scale paths (heartbeats, eviction, aggregates), and
the store layer. Each finding names the mechanism, the measured cost, and the
change made. Numbers are from `coordinator/registry/fleet_scale_bench_test.go`
(1,260 providers, 15 models, live heartbeats, in-flight pending requests) on an
Apple M4 Max unless stated otherwise.

## 1. Why now

The 2026-09-01 congestion collapse (PR #799) showed the coordinator's per-request
CPU cost is dominated by full-fleet walks: every request scans all ~1,260
providers at least twice (capacity preflight + reservation scan), and the failure
path re-scans up to 64 times. PR #799 bounds the retry ladder and adds a scan
semaphore; this program attacks the cost of each scan and of everything else on
the request path.

## 2. Baseline (before)

| Benchmark | ns/op | B/op | allocs/op |
|---|---:|---:|---:|
| FleetReserveProviderEx (scan + commit + release) | 403,844 | 186,309 | 824 |
| FleetReserveProviderExParallel (GOMAXPROCS=16) | 355,349 | 231,610 | 1,027 |
| FleetQuickCapacityCheck (preflight) | 151,308 | 80,976 | 672 |
| FleetHeartbeat (ingest) | 529 | 449 | 6 |
| FleetListModels (`/v1/models` aggregate) | 180,489 | 249,272 | 1,281 |

CPU profile of the reservation scan (top of `pprof -top`):

| Share | Where | Mechanism |
|---:|---|---|
| 35% | `runtime.walltime` | `time.Now()` per provider — `snapshotProviderLockedEx` calls it before any gate, so all 1,260 providers pay it even though ~90% do not advertise the model |
| 8.5% | `runtime.duffcopy` | `routingSnapshot` (large struct) copied by value through snapshot → candidate → discount |
| 3% | `healthEjectionEnabled` | `os.Getenv` + `ToLower`/`TrimSpace` per provider per scan |
| 3.5% | `prefixCacheV2CapabilitiesForModel` | second full fleet walk per request, `p.mu` on every provider, run even with cache routing off |
| ~2% | `slices.pdqsort` | `TPSRegistry.Median` copies + sorts up to 50 samples per provider |
| ~2% | `runtime.concatstrings` | `providerID + ":" + model` map keys for every cooldown/breaker/clamp gate |
| ~4% (alloc) | `versionSegments` / `strings.Split` | semver re-parsed per provider per scan |

Allocation profile: `buildCandidateWithReason` 44% (one heap candidate with an
embedded snapshot copy per eligible provider), `TPSRegistry.Median` 23%,
`providerPooledTokenBudgetWithLayout` 11% (a map per provider per snapshot).

End-to-end (`EIGENINFERENCE_PERF_E2E=1 go test ./api/ -run TestPerfE2E`; real HTTP,
in-process WebSocket fake providers answering instantly, memory store, 16 KB
bodies, 40 streamed chunks):

| Fleet | Concurrency | Throughput | TTFB p50 / p95 | Total p50 / p95 |
|---|---:|---:|---|---|
| 100 providers | 16 | 1,523 req/s | 6.8 ms / 9.7 ms | 10.2 ms / 14.0 ms |
| 1,000 providers | 32 | 524 req/s | 42.3 ms / 54.7 ms | 62.1 ms / 83.0 ms |

Ten times the fleet costs six times the first-byte latency with providers that
respond instantly: the per-request fleet walk is the coordinator's dominant
cost at production scale.

## 3. Hot-path inventory (per chat completion, success path)

| Stage | Cost mechanism | Finding |
|---|---|---|
| `requireAuth` | API key cached (60s) but `GetUserByAccountID` is a Postgres round trip on every request | uncached |
| `parseInferencePrelude` + `handleChatCompletions` | body parsed once, then re-marshalled/re-parsed 6–9× (tool-constraint validation re-parses the original body; alias/reasoning/defaults/max_tokens each re-marshal; `providerBodyForModel` recomputed for the same model) | CPU + allocs proportional to body size, up to MBs with inline media |
| `GetModelRegistryRecord` | two queries per call, called 3–4× per request | uncached |
| `reserveInferenceBalance` | one round trip | necessary |
| `runInferenceAdmission` | `QuickCapacityCheck` full fleet walk | see §2 |
| `ReserveProviderEx` | full fleet walk + global write-lock commit | see §2 |
| `recordRoutingDecisionFor` | one INSERT per attempt through a 1-worker, 4096-deep sink | write amplification, drops under a slow DB |
| streaming relay | one `Fprintf` + `Flush` (syscall) per token; seven `strings.Contains` per chunk | per-token syscalls |
| `handleCompleteAt` | `GetUserByAccountID` again, three separate credit transactions, usage insert | 4–6 round trips per completion |

Fleet-scale: `Registry.Heartbeat` is cheap (0.5 µs); the API-side heartbeat
branch adds capacity deep-copies and telemetry; `ListModels` re-aggregates the
fleet on every `/v1/models`; `/v1/stats` is cached, other public endpoints are
not.

## 4. Changes

_(per worker, in merge order)_

### 4.1 Store read-through cache (`store/cached.go`, `store/cached_domain.go`, `store/cached_clone.go`)

`store.NewCached` wraps both backends at construction in `cmd/coordinator/main.go`.
It overrides only the hot-path lookups and the mutators that can change them:

| Cached lookup | TTL | Invalidated by |
|---|---|---|
| `GetUserByAccountID`, `GetUserByPrivyID` | 30 s | `CreateUser`, `SetUserRole`, `SetUserPlatformFeePercent`, `SetUserStripeAccount` (whole user domain) |
| `GetModelRegistryRecord`, `GetModelManifest` | 10 s | every model-registry writer (whole model domain) |
| "not found" results | 5 s | same |

Reads return deep copies, a generation counter drops loads that raced a
write, domains are bounded (10k users, 1k models) with random eviction, and
transient DB errors are never cached. Effect: the per-request `requireAuth`
user lookup and the 3–4 registry-record lookups (two queries each) become
in-memory hits after the first request per key/model. Single-process
assumption documented in the file header; TTLs bound staleness from
out-of-band SQL edits.

Decorating the store hides backend-only capabilities that callers discover by
type assertion (`codeAttestPushBudgetStore`, `verificationDuePageStore`), which
would have silently downgraded APNs push-budget durability and verification-job
pagination. `store.As[T]` walks `Unwrap()` through decorators and the four
assertion sites use it; tests pin that both capabilities survive the wrap.
Cache counters are emitted as `store.cache.*` gauges per domain.


## 5. After

_(pending)_

## 6. Not done / recommendations

- The container runs with no `GOMEMLIMIT`/`GOGC` (deploy/gcp/vm-startup.sh); a
  soft memory limit tuned to the VM would let the GC run less often under the
  allocation rates measured here. Deploy-side change, human-only.
- pprof listener: PR #799 adds `EIGENINFERENCE_PPROF_ADDR`; not duplicated here.
