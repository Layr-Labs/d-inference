# program.md — the loop

This is the Karpathy autoresearch `program.md` for Qwen 3.6 prefill.
You are not training a GPT. You are tightening a serving Metal/MLX
continuous-batching prefill path. The spirit is the same: one metric,
short experiments, git as memory, ratchet only upwards.

## Immutable

- `research/qwen36-prefill/GOAL.md` — the objective. Always re-read.
- The model snapshot on the Mac. Do not silently swap weights.
- Weight contract: model weight bytes and hashes are immutable.
- Numerical policy is mutable after the 2026-08-24 owner override.
  Checksum differences must be reported and quality-evaluated; they are
  not, by themselves, a reason to stop an otherwise promising path.
- `prepare`-equivalent: the baseline harness
  `darkbloom benchmark --scheduler-prefill` and
  `darkbloom benchmark --arrival-invariance`.
  Do not "improve" the harness to make a number look better.

## Mutable

Anything in `libs/mlx-swift-lm` (Qwen35, SwitchLayers, CBv2, Metal ops)
and the thin Darkbloom wiring in `provider-swift` that selects those
paths. One conceptual change per experiment.

## The 9-step iteration

1. Read `GOAL.md`, then `JOURNAL.md` last 30 lines, then `results.tsv`.
2. Read `MINDMAP.md` and the newest `notes/` files. Do not repeat a
   `status=dead` idea without a new mechanism written down first.
3. State a single hypothesis: "X is on the critical path; changing Y
   will raise aggregate prefill tok/s by Z because of mechanism M."
4. Implement the smallest change that tests that hypothesis.
5. Commit the change on a work branch **or** keep a named patch. Record
   the commit / tree state in `results.tsv`.
6. Run the fixed harness on the M3 Max, High Power, AC, quiet machine.
   Record power posture. Budget wall-clock so runs stay comparable
   (prefer 3-iter medians at 2,048 and 8,192; B=1/2/4).
7. If crash / OOM / `fatalError`: log, revert, stop that line. If outputs
   differ, record the delta and run the preregistered quality gate; keep or
   reject on quality, not checksum identity alone.
8. Append one row to `results.tsv`. Update `JOURNAL.md`.
9. If the primary metric improved **and** reviewer gates pass: keep.
   Else `git reset` the experiment commit. The tree only moves up.

## Metric

```
aggregate_prefill_tps = sum(prompt_tokens_finished) / wall_clock_makespan_s
```

Primary score for the ratchet: **B=4 equal-length 8K burst aggregate
prefill tok/s** on this Mac, CBv2, contiguous KV, prefix cache off,
text-only, temp=0.

Secondary (must not regress silently):

- B=1 8K tok/s and TTFT
- B=2 8K aggregate tok/s
- B=1 2,048 tok/s (short-prompt / chunk-overhead regime)

A change that wins B=4 by destroying B=1 is not a keep unless GOAL.md
is explicitly amended. The user asked for B=1, B=2, B=4 **and**
aggregate. Prefer Pareto improvements.

## Validity gates (void the run if any fail)

- AC power, `powermode=2` (High Power), battery not collapsing mid-run
- No concurrent compile / other GPU user
- Same binary family recorded (version + git sha + env knobs)
- Control cell reproduces the current baseline within 8% before a new
  claim is published
- Temp=0 / greedy for timing cells that will be compared numerically

## Reviewer kill-switch

The reviewer rejects a keep if any of:

- No before/after on the Mac
- Weight bytes changed, numerical change hidden, or quality gate failed
- Only a microbenchmark, no full-model CBv2 number
- Cannot be expressed as a Darkbloom-integrable PR (hidden env-only
  hack that serving can never turn on, coordinator-invisible
  semantic change, untested Metal `fatalError` path)
- Decode throughput or uptime is sacrificed the way v0.8.8 was

## Cadence

Prefer many small runs over one giant rewrite. Overnight energy goes
into packed-prefill verification, chunk/stripe policy, and traffic
deletion — not into mega-kernels that already lost.
