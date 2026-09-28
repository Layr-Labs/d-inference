# Installed two-Mac Qwen9B HTTP first-content timing

> Last updated: 2026-09-15 · commit `605651bb9`

The installed distributed Darkbloom endpoint completed short and 4K requests.
An 8K request missed its first-content deadline in fresh serial and lookahead
sessions, then passed at 16.910756916 seconds after a completed 4K request in
the same lookahead session. These development observations do not establish
representative SLA compliance, a solo speedup, or a release qualification.

## Installed path and measurement

Both 24 GB and 48 GB M4 Pro Macs ran the installed Provider CLI and native
worker, using JACCL over the Thunderbolt RDMA devices and authenticated owner
control. The 24 GB leader owned layers 0–3 and the embedding; the 48 GB follower
owned layers 4–31 and the output projection. Prompt chunks contained 512 tokens.
The real command was `darkbloom start --local --distributed`; requests reached
its authenticated `/v1/chat/completions` endpoint from the separate development
Mac over Tailscale. This is not the upstream OpenRouter route.

All requests used the registered Qwen3.5 9B 4-bit artifact, greedy sampling,
thinking disabled, MTP off, B1 and 128 requested output tokens. Model weights
remained resident within a session; request KV/recurrent state was fresh and
prefix caching was disabled. The warmed-session pair changed neither the model,
installed binaries, selected lookahead plan, deadline nor client settings.

The external client's monotonic clock started immediately before HTTP POST.
First content means the first complete SSE event with nonempty `delta.content`;
the assistant-role event and empty/reasoning-only events do not count. Total
time includes terminal framing and response-body EOF. A passing request required
a complete stream and first content before `10 seconds + 1 ms × input tokens`.
Neither `input tokens / TTFT` nor SSE event rate is presented as engine TPS.

## Individual request outcomes

Each fresh-session row has one request. The last two rows share one session in
the displayed order. The completed 4K warmup remains recorded but is excluded
from the following 8K request's measurement.

| Session / schedule | Input tokens | First content (s) | Deadline (s) | Total client time (s) | Output tokens / finish | Outcome |
|---|---:|---:|---:|---:|---|---|
| Fresh / serial | 42 | 1.339245042 | 10.042 | 5.220690750 | 128 / length | Pass |
| Fresh / serial | 963 | 2.461908417 | 10.963 | 6.341170583 | 128 / length | Pass |
| Fresh / serial | 4,096 | 9.755173625 | 14.096 | 13.707597459 | 128 / length | Pass |
| Fresh / serial | 8,192 | None | 18.192 | 18.321215541 | No terminal usage | Miss; incomplete stream |
| Fresh / lookahead | 8,192 | None | 18.192 | 18.300895541 | No terminal usage | Miss; incomplete stream |
| Warmup / lookahead | 4,096 | 8.937706041 | 14.096 | 13.189477000 | 128 / length | Pass |
| Same session after warmup / lookahead | 8,192 | 16.910756916 | 18.192 | 21.070420375 | 123 / stop | Pass; EOS shortened |

The warmed 8K request had 1.281243084 seconds of deadline margin. Its 123
reported completion tokens include the stop token; there were 122 nonempty
content events. It is not a completed 128-output-token benchmark cell.

Both 8K misses received HTTP 200 and only an initial assistant-role event.
The Provider reported a runtime failure near the deadline and its actual CLI
exit status was 64. There is no captured per-rank failure-cause transcript in
these runs, so the precise internal cause is not established by the timing.
The successful warmed request supports investigating cold-session overhead;
one observation does not isolate compilation from every other cold effect.

The nonrepeated 4K/8K development prompts use retained MLX source text. The full
pinned thinking-disabled chat template and tokenizer produced the expected
counts. Before each 8K generation run, the actual Swift `/tokenize` endpoint
matched all 8,192 prepared IDs for the rendered prompt; this CPU preflight was
outside generation timing. Successful terminal usage independently reported
the displayed counts. These prompts have no new full-model numerical comparison.

## Resources and cleanup

An earlier serial attempt was stopped before any HTTP request when actual free
memory fell below the unchanged 6 GiB floor on the 24 GB Mac. That failure is
retained separately. Cache purges preceded subsequent designated attempts;
no application was closed, memory floor lowered, bridge reset or reboot used.

Every timed row above passed the retained AC-power, zero-swap, pressure and
actual-free-memory checks. The warmed pair retained 165/154 samples, with
minimum actual free memory of 6.528015137/25.746551514 GiB on the 24/48 GB Macs.
Sampling does not establish continuous peak-memory bounds.

After each session, both workers were absent, both canonical ownership journals
were empty and the bounded temporary Thunderbolt IPv4 alias was restored. No
forced kill was used. Successful sessions had actual CLI exit zero; misses
retained their nonzero status. Hummingbird shutdown diagnostics are retained,
not described as an empty stderr. The HTTP client alone supplies no native
retirement proof; the enclosing supervisor and postflight supply these checks.

## Evidence and limitations

Raw receipts, SSE arrivals, resource samples and exact source snapshots remain
under `/Users/developer/DarkbloomDev/cluster-research/`:

- `installed-product-http-qualification-20260915/physical-1` through `physical-5`:
  initial resource refusal, three serial passes and serial 8K miss.
- `installed-product-lookahead-http-qualification-20260915/physical-1`:
  fresh lookahead 8K miss.
- `installed-product-warm-http-qualification-20260915/physical-1`:
  both warmup and measured client receipts, unchanged source pins and cleanup.
- `installed-http-long-prompts-20260915/fixture-manifest.json`:
  `5d97049c6998aaab9f1e85c3a56ab079642227f3d724e0e56c283fe6f3a2a240`.

The serial cohort used native worker SHA
`b8335e55de6e681e9b1b7be6ae6a64e57380cc20b3d6e6c13587517afee0a1d1`;
the lookahead sessions used
`ffcbd7de0ccc5a8b35881f9dd5ed5b6fcb8a2f5bdc7e7b63fa1e46bd9c79bba5`.
Both paired a release native worker with a debug Provider build. The different
serial/lookahead binaries do not form a controlled schedule-speedup pair.

The earlier [internal timing report](2026-09-15-cluster-lookahead-generation-and-timing.md)
uses a different diagnostic prompt and excludes a full 8K warmup. It cannot
replace these external measurements. Representative balanced prompts/repeats,
optimized solo controls, cold readiness policy, HTTP cancellation, sustained
serving and upstream routing remain open in the
[execution plan](../design/distributed-cluster-execution-plan.md). No 27B,
Gemma, active-MTP or M3 Ultra performance result is established here.
