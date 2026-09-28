# Installed cluster diagnostics, disconnects and smaller warmup

> Last updated: 2026-09-15 · commit `605651bb9`

The installed Qwen9B development build reports live readiness on both Macs and
recovers through a fresh session after controlled HTTP disconnects. Cancellation
after visible output passes; cancellation during prefill remains incorrect in
this build. A 512-token warmup precedes an 8K request that meets the first-content
deadline at 16.902159625 seconds. These are individual development observations.

## Candidate and measurement

Both M4 Pro Macs (24 GB and 48 GB) run the development bundle
`installed-distributed-diagnostics-runtime-20260915`. The Provider debug binary
is `08b0190fb0870bee036a57c0143ee53568bd9400a0f9c0d9af50f7442c8b76df`;
the native Release binary is
`ffcbd7de0ccc5a8b35881f9dd5ed5b6fcb8a2f5bdc7e7b63fa1e46bd9c79bba5`.
The latter is unchanged from the preceding lookahead measurements. The working
tree contains uncommitted cluster changes, so the commit stamp alone does not
identify these binaries; retained source manifests and artifact hashes do.

The configured registered Qwen3.5 9B 4-bit model uses layers 0–3 on the leader,
layers 4–31 on the follower, 512-token chunks and one-chunk prefill lookahead.
MTP and prefix caching are off. Requests use greedy decoding, thinking disabled
and 128 requested output tokens. The development Mac sends authenticated HTTP
requests over Tailscale to the installed Darkbloom endpoint; this is not the
OpenRouter route. TTFT starts before the client POST and ends at the complete
first SSE event containing nonempty `delta.content`.

The candidate's combined Provider/CLI validation passes 85 tests in 13 suites,
with 1,342 source pins unchanged. Actual stopped `cluster status --json` and
`cluster doctor` checks pass on both machines; stopped metadata is not reported
as live readiness. The new HTTP cancellation correction was not part of this
candidate and was still awaiting compilation when these measurements ran.

## Disconnect cause and fresh-session recovery

| Controlled disconnect | Actual terminal cause | Both workers absent and journals empty, observed after client close | Qualification |
|---|---|---:|---|
| Before content, 8,192-token request; client closes at about 0.517 s | `prefill_stall` | 18.918853 s | Fails prompt client cancellation; the native prefill deadline caused cleanup |
| After two nonempty content fragments of a 42-token request | `cancelled` | 1.567406 s | Passes this after-content cancellation case |

Neither observation used a parent stop or forced kill to produce the cleanup.
The actual CLI exits with runtime status 1, without argument-usage output. In
the first case the Provider records terminal at 18.068469 seconds and retirement
at 18.161144 seconds from its request origin. Procedural autonomous cleanup
therefore cannot be counted as prompt cancellation.

In the second case first content arrives at 0.394119875 seconds, and the client
finishes closing at 0.426699917 seconds. The Provider records terminal at
0.480377041 seconds and retirement at 0.600576125 seconds from its own request
origin. These are separate clocks, not a cross-process latency subtraction.
The server reports five committed tokens. Two visible fragments do not establish
two received tokens, and tokens generated after cancellation were not measured
independently.

Each case is followed by a separately started session and one normal request:

| Recovery after | Input tokens | First content (s) | Deadline (s) | Total client time (s) | Output / finish |
|---|---:|---:|---:|---:|---|
| Before-content disconnect | 42 | 1.324611916 | 10.042 | 5.236556500 | 128 / length |
| After-content disconnect | 963 | 2.301142625 | 10.963 | 6.186925167 | 128 / length |

Both responses include terminal usage, DONE and body EOF. Actual CLI status
before and after each request reports both native workers ready, the same
membership epoch within that session, distinct observation nonces, and remaining
request admissions decreasing from 16 to 15. Status is outside client timing.
Both sessions stop normally with exit 0, no forced kill, empty journals and no
native processes. This validates fresh startup recovery, not automatic in-place
session replacement or sustained serving beyond the configured limits.

## Smaller warmup observation

One new session serves the following two requests in order. The warmup retains
its own complete measurement; its time is excluded only from the following
request's TTFT. The server uses fresh request state, with no prefix-cache reuse.

| Request | Input tokens | First content (s) | Deadline (s) | Total client time (s) | Output / finish |
|---|---:|---:|---:|---:|---|
| Warmup | 512 | 1.383103000 | 10.512 | 4.430924042 | 99 / stop |
| Following request | 8,192 | 16.902159625 | 18.192 | 21.001253958 | 123 / stop |

The actual Swift tokenizer matches every prepared ID for both requests before
generation. Both normal HTTP clients pass, including terminal framing and EOF.
Their 99 and 123 reported output tokens include stop tokens; the client observes
98 and 122 nonempty content events. Neither row is a completed 128-output-token
benchmark cell. The 8K first-content margin is 1.289840375 seconds.

The whole procedure takes 36.292994042 seconds. The Provider stops normally,
both native processes are absent, journals are empty, and the temporary
Thunderbolt alias is restored. All 134/125 resource samples pass the unchanged
AC, zero-swap, normal-pressure and six-GiB actual-free-memory guards. Minimum
actual free memory is 6.572403 GiB on the leader and 25.929245 GiB on the follower.

This observation motivates further cold-overhead investigation. It does not
identify the causal mechanism, implement a startup-warmup policy, or prove a
performance improvement over the preceding 4K warmup on a different Provider
binary. The earlier cold 8K misses remain valid failed results.

## Retained evidence and limits

Raw artifacts are under `/Users/developer/DarkbloomDev/cluster-research/`:

| Evidence | Directory |
|---|---|
| Provider build/tests | `cluster-diagnostics-main-integration-20260915/provider-tests-2` |
| Installed status and doctor | `installed-distributed-diagnostics-operator-checks-20260915` |
| Before/after-content disconnects | `installed-http-cancellation-diagnostics-20260915/harness/physical-3` and `physical-4` |
| Fresh recovery sessions | `installed-product-diagnostics-http-qualification-v2-20260915/physical-1` and `physical-2` |
| 512-token warmup then 8K | `installed-product-small-warm-http-qualification-20260915/physical-1` |

Each successful normal recovery retains 22 exact source inputs; the smaller
warmup experiment retains 29. Disconnect causal reviews distinguish procedure
completion from cancellation correctness. Separate recovery-link receipts bind
each fresh recovery to its preceding disconnect without changing old outcomes.
Earlier harness failures are retained: a missing helper prevented startup, and
a cross-process Python monotonic-clock comparison was corrected to use the same
OS clock on both sides. That cleanup-clock fix does not change within-client
TTFT measurement.

Representative workload percentiles, matched optimized solo speedup, actual
OpenRouter SLA compliance, MTP generation, larger models and M3 Ultra performance
remain unqualified. No release is published by this work. See the preceding
[installed HTTP report](2026-09-15-cluster-installed-http-ttft.md) for cold misses
and the [execution plan](../design/distributed-cluster-execution-plan.md) for the
remaining delivery scope.
