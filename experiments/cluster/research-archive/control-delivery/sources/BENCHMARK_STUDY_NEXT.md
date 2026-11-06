# Paired prefill benchmark next steps

Current update (2026-09-15 UTC): [resident worker handoff](RESIDENT_WORKER_NEXT.md)
records the isolated native build and CPU checks, ten completed development
inputs, adapter integration limits, and returned-machine status. The earlier
notes and evidence below are preserved as history; use that handoff for the
current workload and hardware state.

The public module is `d-inference/experiments/cluster/benchmarking`.
`specification.read_study` validates ten distinct raw prompt pins and a matched
solo/distributed pair; `make_schedule` produces twenty four-request cohorts,
with five solo-first and five distributed-first prompt pairs. Each cohort has
one excluded warmup and three measured requests. `coordinator.run_study` uses
an injected context-managed adapter and stops without replacement or retry on
any request, measurement, entry, cleanup, event-sink or interrupt failure.

`aggregate.summarize` revalidates the exact schedule, preserves missing/failed
samples and computes the median of ten per-prompt medians of individual TPS.
It uses Fraction arithmetic for comparisons before presenting JSON floats.
An incomplete cohort withholds both condition aggregates; per-prompt samples,
paired comparisons and sample-counted latency tails remain available.
The source/runtime/timing/hardware claims remain externally unverified and
performance qualification/runtime admission remain false.

All 35 tests pass under Python 3.14 and 3.9.6. Seven Python files parse as 3.9.
The final root record is
`runs/paired-prefill-study-cpu-20260914/execution.json`, SHA
`12f0f841f8a547fc5fdd7b5907dafeed0b95942ddd73c220cf377571ec31e325`.
It retains fabricated complete (20 cohorts / 80 calls), warmup-failure
(1 cohort / 1 call) and final-close-failure (20 cohorts / 80 calls, still
incomplete) executions. These are CPU framework tests, not model measurements.

Source review fixed an exception-message formatting failure that could prevent
retention of an adapter error. Root also covered cleanup/publication failure
precedence, operator interrupts and context-manager exception suppression.
The code is separated into specification/schedule, aggregation and orchestration;
no generic catch-all or runtime source changes were needed. Public documentation
and developer test navigation are updated. Public content scan: 603 files and
591 relative links, SHA
`0dd8efbd5e21b77d52a48761490aa6cff10ab6a8584a4f5ef9571fb209466c9b`.

The next concrete integration requires a resident execution adapter plus real
workloads. The only inspected 8K input is repeated diagnostic prose; its
`long-prefill-input-20260914/tokenization.json` explicitly makes no representative
workload claim. Do not relabel or duplicate it into a ten-prompt qualification
set. Freeze separate development and qualification workloads with raw token,
origin and tokenizer identities. Verify exact 8192-token/fresh-state conditions.

Native resident rank implementation exists in
`QwenLongPrefillResidentRankOwner.swift` as
`runQwenLongPrefillResidentRankCohort`; its private owner retains weights across
at most sixteen requests and creates fresh state for each request. It is an
internal batch function with no CLI, not a drop-in interactive `runner.run`
adapter. A future bridge must preserve the coordinator's per-request execution
contract and failure boundary; it must not compute later requests eagerly while
reporting them as unattempted/skipped. A matching solo owner can reuse the actual
`runQwenLongPrefillSoloRequest` body with explicit weight residency and retirement.
Do not increase one-shot --warmups/--repeats flags and claim that as this adapter.

Any new native admission remains separate from this CPU module. The current
registered 9B long path is loopback and its original gates remain unchanged;
27B/M3/physical distributed qualification is outstanding. Preserve native c079
until its existing tiny regression and registered short-parity command can run
under the original resource/power gates; use a separate prototype/build snapshot
if continuing new native-source work before that qualification.

Latest read-only hardware check: 2026-09-14 18:47:26 UTC, peer24 online at 10%
battery and discharging; peer48 SSH timeout. Receipt
`peer-power-connectivity-20260914-184726.json`, SHA
`96c172fa5a141387e839f7b2a7f07c8eaa54b862806b2f7e46d6ae25f877ae32`.
No native model job, purge, reboot or network mutation was performed. The
800 TPS acceptance and 1000 TPS stretch goal remain active and unqualified.
