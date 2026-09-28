# Installed distributed HTTP configured-deadline terminal

> Last updated: 2026-09-15 · commit `605651bb9`

An actual two-Mac request with an explicitly configured two-second generation
deadline delivers a typed failure, attempt usage, `[DONE]` and HTTP body EOF to
its connected client. Native ownership retires and both original configuration
references are restored. The inference request fails; this controlled negative
test does not reproduce a natural 18.192-second first-content miss.

## Scope and installed inputs

The test uses the same installed development binaries as the
[HTTP cancellation and recovery observation](2026-09-15-cluster-http-delivery-recovery.md):
Provider `c4083695c07ed7da819284e48de3aeb8786940b43271fa6e974b469c26f10350`
and native worker
`ffcbd7de0ccc5a8b35881f9dd5ed5b6fcb8a2f5bdc7e7b63fa1e46bd9c79bba5`.
The commit stamp alone does not identify the installed uncommitted source.
No runtime code or binary changes are made for this test.

The registered Qwen3.5 9B 4-bit model runs on the 24 GB and 48 GB M4 Pro Macs,
with cut 4, 512-token chunks, one-chunk lookahead, greedy selection, thinking
disabled and MTP off. The external client requests 128 output tokens from an
8,192-token prompt. Before the timed request, all 8,192 prepared token IDs match
the actual Swift tokenizer response. This checks the input, not generated-token
or model correctness.

Both default provider references temporarily select
`darkbloom-product-qwen9b-configured-deadline-20260915`. The only configuration
changes are that cluster ID and `requestTimeoutSeconds` from 120 to 2.
Capability, model, trust, runtime, Plan, scheduling and native resource limits
remain pinned. The canonical temporary leader and follower hashes are
`7f2a82af486b2b58ed17a620b51e8ceceaf187e7a1f781f91d36bf1aa9a9c536`
and `8d895c8217ea0896e406069faa92770bbe6d651d7ea4de8c866274fde4df967c`.

A fresh authenticated local status observation reports both ranks loaded and
ready in epoch `ee59d77a-8b47-4e97-9024-5b339f20d31b`, with 16 remaining
admissions. Rank 0 uses local pipes and rank 1 uses authenticated SSH; native
inference uses the Thunderbolt link. Status and tokenization are outside the
client timing. No startup preparation request is installed or run.

## Connected client outcome

The unchanged external content SLA is 18.192 seconds. The observer keeps its
90-second observation bound so it can capture failure delivery; neither bound
extends the configured two-second generation deadline.

| Observation | Time from the client's request send |
|---|---:|
| Role-only event complete | 0.452460250 s |
| Typed error event complete | 2.144623750 s |
| `[DONE]` complete | 2.146428459 s |
| Actual HTTP body EOF | 2.146525125 s |

The response is HTTP 200 because the SSE stream has already begun. Its complete
448-byte body contains one role event, three keepalive comments, this terminal
failure and `[DONE]`:

```json
{"attempt_usage":{"completion_tokens":0,"prompt_tokens":8192},"error":{"code":"inference_error","message":"Distributed generation did not complete","terminal_cause":"safety_deadline","type":"server_error"}}
```

There is no content, reasoning, successful finish reason or successful usage
record. The client exits 1 and retains `status: failed`; inference success and
the original content-SLA result are both false. The enclosing harness exits 0
only because the intended failure, complete delivery, cleanup and restoration
checks pass. This is not a successful inference result or a throughput sample.

## Retirement and resources

For one request ID, the Provider records `reserved`, `terminal` with
`safety_deadline`, then `retired`, all with 8,192 input tokens, zero committed
outputs and zero dropped observations. Their engine-admission elapsed times
are 298.029792, 1,868.476500 and 1,992.168375 milliseconds. Retirement follows
terminal by 123.691875 milliseconds. These are the Provider's own elapsed
times; they are not subtracted from the client's clock or treated as its
request-send origin.

The first paired observation after body EOF finds both native processes absent
and both canonical device journals empty. It completes 0.334185 seconds after
client close. No parent stop or forced kill is issued; the actual serving CLI
exits naturally with runtime-failure status 1. Separate per-rank ACK transcripts
are not retained: the evidence combines the Provider retirement event, actual
CLI exit and process/journal observations. Hummingbird `Already closed` and
`CancellationError()` shutdown diagnostics remain in the retained stderr.

| Host | Resource samples | Minimum sampled actual free memory |
|---|---:|---:|
| 24 GB leader | 43 | 10.239716 GiB |
| 48 GB follower | 39 | 24.720612 GiB |

All 82 raw samples recompute to the saved values: AC power, pressure level 1,
zero reported swap and at least six GiB actual free. Maximum sampling gaps are
about 302 milliseconds. Actual free is page size times the `vm_stat` printed
free-page count, which already excludes speculative pages. Periodic samples
do not establish a continuous minimum or a whole-process allocator bound.

The temporary Thunderbolt IPv4 alias is removed. Retained interface/GID and
management-route observations match their preimages; bridge membership is
unchanged.

## Configuration restoration and evidence

The transaction stages both configurations before switching either default.
Successful restoration commands run only after process absence and an empty
canonical device journal, under the existing locks. Their readbacks recover
the original provider TOML hashes and mode `0600`:

| Host | Original and restored provider TOML SHA-256 |
|---|---|
| Leader | `dea0e291200e111d0fbc5f8e549db5054546aeeaf963a854519804e3c5c675d6` |
| Follower | `47c083ac6eb0d7926b4bd468437e3d6dea1dc92e9bc44e63a133c4cc907f941e` |

All six prepare/install/restore command receipts have exit 0 and empty stderr.
The transaction records `defaultsRestored: true`, with no restoration or
recovery errors. The independent review verifies these captured hash/readback
receipts; it does not perform a later remote reread of the backup files.

Evidence is retained under `/Users/developer/DarkbloomDev/cluster-research/`:

- `installed-http-configured-deadline-qualification-20260915/manifest.json`
  freezes the 55-member harness as
  `b130dc4d007b4f699cb56712b954d00ede0a8e91db7c20094a1a25f6a63d9c19`.
- Its `harness/physical-1` retains the SSE bytes, all 12 arrival records,
  client receipt, actual status/tokenizer responses, Provider logs, supervisor
  exit, resource samples and cleanup observations. Its `execution.json` is
  `4b0af05002be0e3ebfa28c3ec24f3586c4510babfb6f92cd1b351258c5053437`.
- Its `transactions/attempt-1` retains the six configuration command outputs
  and receipts, plus the paired restoration result.
- `installed-http-configured-deadline-review-20260915` retains an independent
  parser/recomputation and the input hashes, without importing the client or
  harness validators. It does not execute remote commands, inference or a
  compiler, and it changes no frozen evidence.

The observation closes this configured connected-terminal case. It does not
establish natural cold-8K SLA reliability, general peer-failure recovery,
automatic session replacement, OpenRouter eligibility, numerical correctness
or release qualification. Earlier reports remain unchanged.
