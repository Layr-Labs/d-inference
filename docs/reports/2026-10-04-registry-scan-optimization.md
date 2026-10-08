# Registry scan optimization measurement record

> Last updated: 2026-10-04

This record measures the combined registry optimization against master
`c5552d3af7ae725f956a2911b44d3e933da4b94c`, the merged #1340 implementation.
Measurements use an isolated checkout on an Apple M5 Pro Mac mini, 18 logical
CPUs, 48 GiB memory, macOS 27.0, cached Go 1.25.0 and `GOMAXPROCS=12`.
Existing user checkouts and services were left untouched.

## Implemented opportunities

| Opportunity | Final implementation | Preserved contract |
|---|---|---|
| Reusable private candidate storage | Exclusive lazy borrower in `reservation_storage.go`; all historical chunks cleared after consumption. | Public scans and decorated preparations own their storage; copied decisions/plans and committed winners outlive private reuse. |
| Compact retained candidates | Candidate size falls from 1,448 to 592 bytes; transient `routingSnapshot` stays on the scan stack, detached `candidateSnapshot` retains quote/ranking/diagnostic inputs. Chunk size increases from 22 to 55. | One canonical provider/model binding, immutable public quotes and fresh locked commit revalidation. |
| Borrow evidence and project alternates once | Forecast/calibration functions borrow immutable evidence; `selection.RetainRanked` projects selection values once. | Prediction still copies work before adding the request; every alternate recomputes ranking classes and consumes the same random draws. |
| Aggregate pending and service evidence | One pending traversal freezes scalar content state, with a 16-item inline buffer and normal spill. One owner-bound service validation is shared inside the provider critical section; competitor maps allocate lazily. | Prompt/maximum-output memory remains reserved until retirement; exact UUID lease overlap, finite usage bounds and physical admission remain enforced. |
| Bound oversized-scan reuse costs | Indexed scans above `MaxReusableCandidates = 64 * 55 = 3520` use owned chunks immediately. Reusable objects retain at most 64 chunks; extra fail-open chunks are request owned. | Approximately 2 MiB retained per object, with no global pool cap. `sync.Pool` may discard idle objects. |

The dedicated refactor pass removed the obsolete private preparation wrapper
chain and retained the public `Prepare`, `Finish` and `Close` lifecycle. An
independent reviewer found no actionable introduced correctness, concurrency,
ownership, reservation or billing defect in the combined coordinator diff.
There are no ledger/store/transaction changes in this implementation; #1336's
separate billing fix was not part of the measured master revision.

## Measurement method

Both variants were compiled before timing. Each of six rounds launches fresh
test processes sequentially; order reverses on alternate rounds. Each case uses
`-test.run=^$ -test.benchmem -test.benchtime=700ms -test.count=1` with
`GOMAXPROCS=12`. No builds, tests or other benchmark jobs ran concurrently with
timing. Tables report medians of six runs, allocated bytes and allocation counts;
the raw sample record retains every run. Paired wins compare the same round.
These small paired samples are descriptive, without a statistical significance
claim. Independent prototype gains are not added together.

The same added benchmark bodies were used on both revisions. The 350-provider
fixture is unchanged on master and optimized code. Scale fixtures use 32, 350,
1260, 3000 or 6000 providers, two or fifteen models, warm/cold engines and zero to
three pending owners. The skew fixture updates real model indexes so one model
has 6000 providers and another has exactly 1000. Pending/service cases have real
local owners and reported UUID service, including 0, 4 and 16 pending requests.
Plan construction uses the actual dispatch shortlist.

The new parallel and writer cases assign globally unique request IDs and assert
that removal returns the exact pending owner. The existing full request-path
parallel fixture has worker-local IDs that can overlap; its result is retained
as a historical comparison, with the new unique-ID case carrying the stronger
reservation-concurrency evidence. Writer load calls `RecordProviderOutcome`
every 2 ms (approximately 500/s). Mean and per-run maximum wait are reported;
maxima are noisy and do not establish production tail latency.

Parallel time/op is elapsed time divided by aggregate completed operations,
not individual request latency. All results measure local registry CPU,
allocation and contention costs. They do not establish production first-content,
network or inference latency.

## Combined results

All 23 cases improve in each of six paired rounds against current master.
The standard 350-provider case reduces allocated bytes by 98.08% and allocations
from 19 to 6; its time reduction is 14.57%.

| Benchmark | master | optimized | Change | Faster paired rounds |
|---|---:|---:|---:|---:|
| BenchmarkFleetReserveProviderEx | 158.406 µs / 202070 B / 14 | 132.605 µs / 4490 B / 7 | -16.29% | 6/6 |
| BenchmarkFleetQuickCapacityCheck | 102.654 µs / 1024 B / 1 | 95.101 µs / 1024 B / 1 | -7.36% | 6/6 |
| BenchmarkReserveProviderExPendingService_350x2/pending0 | 345.252 µs / 448644 B / 300 | 285.709 µs / 8346 B / 6 | -17.25% | 6/6 |
| BenchmarkReserveProviderExPendingService_350x2/pending4 | 545.630 µs / 448643 B / 300 | 414.502 µs / 8373 B / 6 | -24.03% | 6/6 |
| BenchmarkReserveProviderExPendingService_350x2/pending16 | 1440.507 µs / 448641 B / 300 | 1010.708 µs / 8514 B / 6 | -29.84% | 6/6 |
| BenchmarkRequestPathSerial | 197.665 µs / 232954 B / 15 | 165.713 µs / 4874 B / 8 | -16.16% | 6/6 |
| BenchmarkRequestPathParallel | 80.925 µs / 233081 B / 14 | 59.462 µs / 4942 B / 7 | -26.52% | 6/6 |
| BenchmarkReservationScale/providers=32/models=2 | 37.397 µs / 52636 B / 9 | 30.363 µs / 2548 B / 8 | -18.81% | 6/6 |
| BenchmarkReservationScale/providers=32/models=15 | 14.665 µs / 35926 B / 9 | 10.982 µs / 2258 B / 8 | -25.11% | 6/6 |
| BenchmarkReservationScale/providers=350/models=2 | 324.050 µs / 400845 B / 20 | 266.380 µs / 6784 B / 7 | -17.80% | 6/6 |
| BenchmarkReservationScale/providers=350/models=15 | 62.032 µs / 80250 B / 10 | 51.213 µs / 2884 B / 7 | -17.44% | 6/6 |
| BenchmarkReservationScale/providers=1260/models=2 | 1157.162 µs / 1525890 B / 52 | 966.708 µs / 101879 B / 8 | -16.46% | 6/6 |
| BenchmarkReservationScale/providers=1260/models=15 | 196.620 µs / 232850 B / 15 | 165.672 µs / 4778 B / 7 | -15.74% | 6/6 |
| BenchmarkReservationScale/providers=3000/models=2 | 3154.461 µs / 3599621 B / 111 | 2529.655 µs / 228905 B / 8 | -19.81% | 6/6 |
| BenchmarkReservationScale/providers=3000/models=15 | 492.798 µs / 540397 B / 24 | 406.550 µs / 8668 B / 8 | -17.50% | 6/6 |
| BenchmarkReservationScale/providers=6000/models=2 | 7283.225 µs / 7159134 B / 213 | 6187.032 µs / 2322748 B / 66 | -15.05% | 6/6 |
| BenchmarkReservationScale/providers=6000/models=15 | 1140.047 µs / 1120008 B / 41 | 965.371 µs / 66390 B / 9 | -15.32% | 6/6 |
| BenchmarkReservationPlan350 | 390.858 µs / 441530 B / 27 | 314.595 µs / 14804 B / 14 | -19.51% | 6/6 |
| BenchmarkReservationParallel350 | 130.732 µs / 436909 B / 21 | 100.187 µs / 8754 B / 8 | -23.36% | 6/6 |
| BenchmarkReservationReservationWriter | 145.597 µs / 476232 B / 22 | 107.312 µs / 8814 B / 8 | -26.29% | 6/6 |
| BenchmarkReservationSkewedModels/largeEvery=1 | 10294.165 µs / 9530797 B / 282 | 8775.265 µs / 4188526 B / 118 | -14.75% | 6/6 |
| BenchmarkReservationSkewedModels/largeEvery=20 | 1737.300 µs / 1717348 B / 57 | 1454.732 µs / 296956 B / 14 | -16.26% | 6/6 |
| BenchmarkReserveProviderEx_350x2 | 313.661 µs / 435152 B / 19 | 267.959 µs / 8370 B / 6 | -14.57% | 6/6 |

The writer-load median mean wait is 2.474 → 1.663 µs; the median of per-run
maximum waits is 179.100 → 24.295 µs. These are fixture observations only.

A separate six-round, three-variant interleave uses the unchanged 350-provider
fixture on pre-#1324 commit
`48d2be458b3ce511a2a9006238b923295c9c6718`, master and optimized code:

| Benchmark | master | optimized | pre1324 | Change | Faster paired rounds |
|---|---:|---:|---:|---:|---:|
| BenchmarkReserveProviderEx_350x2 | 337.538 µs / 435159 B / 19 | 269.058 µs / 8407 B / 6 | 216.425 µs / 416533 B / 20 | -20.29% | 6/6 |

Optimized routing remains **24.32% slower than pre-#1324** in that block,
although it is 20.29% faster than its simultaneously measured master. The
master medians differ between measurement blocks (313.661 versus 337.538 µs),
which illustrates why cross-block absolute comparisons are unsuitable. Only
this unchanged fixture is compared to the older revision; package/contract
reorganization prevents treating it as a complete equivalent baseline.

All samples for the main, storage-policy and historical blocks are in the
[raw sample CSV](2026-10-04-registry-scan-samples.csv). Binary digests, commands,
UTC run intervals and revision identities are in the
[measurement manifest](2026-10-04-registry-scan-manifest.json).


## Oversized-storage policy comparison

The alternative always borrows the first 64 chunks and allocates overflow as
request-owned chunks. Its hard bound and ownership semantics match the selected
policy. Six interleaved fresh-process rounds give:

| Workload | Early owned fallback | Always-borrow bounded hybrid | Hybrid change | Hybrid faster rounds |
|---|---:|---:|---:|---:|
| 3000 providers, two models | 2509.744 µs / 229072 B | 2517.488 µs / 233004 B | +0.31% | 3/6 |
| 6000 providers, two models | 6206.797 µs / 2299414 B | 6099.391 µs / 1210198 B | -1.73% | 5/6 |
| Skew fleet, wide model every request | 8876.165 µs / 4188528 B | 8844.978 µs / 2113890 B | -0.35% | 4/6 |
| Skew fleet, wide model once per 20 requests | 1478.881 µs / 297948 B | 1504.538 µs / 192143 B | +1.73% | 1/6 |

The selected early fallback avoids increasing pooled high-water clearing for
the common narrow scans in the last workload. Always borrowing saves allocation
on oversized scans and can be slightly faster there, but consistently slows
this representative mixed workload. This is a latency/allocation tradeoff;
early fallback is not claimed universally faster. After compaction, the
3000-provider case fits the pool and both policies take the same path.

## Validation

All commands use cached Go 1.25.0 with offline module resolution and a task-local
build cache. Database environment variables are empty. Local socket fixtures use
only isolated loopback services.

| Check | Result |
|---|---|
| `python3 scripts/run-coordinator-tests.py --jobs 2` | All 21 runner jobs pass in 114.405 s; 91 tested packages, 4298 top-level passes and 111 top-level skips (7921 pass events and 123 skips including subtests). |
| `go test -race ./coordinator/tests/registry/... -count=1 -v` | All eight packages pass; 1512 top-level passes and no reported race. |
| `go vet ./coordinator/...` | Exit 0. |
| `make coordinator-build coordinator-build-linux` | Exit 0 for macOS/arm64 and Linux/amd64. |
| `python3 scripts/test-coordinator-tests.py` | Pass. |
| Ranking differential | 2096 pools, 10258 valid decisions and six malformed zero-choice pools; digest `6dbcdc0f20d108a977607234b2a20752f7488405c6d74b29e10423c4b4d6d842`. |
| Retained alternate differential | 864 cases match successive calls to the production selector, including alternate order and draw trace. |
| Public ownership under private churn | 73 public quotes, held public preparation and eight-entry plan survive 160 concurrent unique private reservations; ordinary/decorated digest `a9b7b868ee136fbe342cd199a07d24423399c06a93acf704a6b457cec0ee3d70`. |
| Storage boundaries | All historical/rejected slots clear, overflow stays owned, fail-open passes do not alias; successful plans and public retention at 3520/3521/3520 indexed providers. |
| Pending/service boundaries | Owner isolation, UUID bounds, non-finite usage rejection, 17-item spill, committed-content output work, exact token/memory admission and post-retirement quotes pass. |
| Borrowed calibration | Successful repeated prediction preserves the complete input work/evidence. |
| Final skew fixture | Normal tests pass on all three policy/base variants; the delivered version also passes its focused race test. |
| `make docs-impact-check BASE=origin/master` / `make docs-check` | Final impact coverage passes; all 331 tracked Markdown documents pass lint. |

PostgreSQL binaries are unavailable and database cases skip without
`DATABASE_URL`; they are not counted as validated. Production/provider E2E and
protected GitHub gates require their own infrastructure and approval. No tools
were installed and no production credentials were used. The host default Go
1.27.1 exhibits four existing JSON parity failures on both the original head and
base, so all acceptance checks use the repository-pinned Go 1.25.0.

After publication, CI identified four unused legacy `routingSnapshot` decode
and shadow-TTFT helpers. They were removed and their stale comments updated;
active callers already use `candidateSnapshot` methods. This cleanup changes
no runtime path. The timing samples above were collected before that deletion.

## Reproduction and remaining costs

From each isolated repository root, compile before timing:

```sh
go test -c -o /tmp/registry-variant.test ./coordinator/tests/registry
GOMAXPROCS=12 /tmp/registry-variant.test -test.run='^$' \
  -test.bench='^(BenchmarkReserveProviderEx_350x2|BenchmarkReservationScale|BenchmarkReservationPlan350|BenchmarkReservationParallel350|BenchmarkReservationReservationWriter|BenchmarkReserveProviderExPendingService_350x2|BenchmarkReservationSkewedModels)$' \
  -test.benchmem -test.benchtime=700ms -test.count=1
```

For a master comparison, copy only the added benchmark bodies and their fixture
into its mirrored registry test package, leaving production source untouched;
the unchanged existing fleet helpers supply the remaining setup. Do not copy
the new implementation-dependent correctness tests. Repeat six fresh-process
rounds with reversed order, matching toolchain, CPU count and benchmark duration.

Scanning and ranking still grow with indexed providers. Detached selection
projection, public owned scans, large owned candidate chunks, retained alternate
entries, full historical pool clearing and concurrent borrowers remain real
costs. The pool limit is per object, so retained memory is proportional to
simultaneously cached borrowers. No persistent provider-report cache or index
was introduced. Further candidate-field compaction is unmeasured; the measured
592-byte layout is the delivered implementation.

Canonical contracts and code maps are in [routing](../architecture/routing.md),
[first-content routing](../architecture/first-content-routing.md) and
[testing](../developer/test.md).
