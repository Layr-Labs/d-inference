# Installed Qwen9B first-request 8K observation

> Last updated: 2026-09-15 · commit `605651bb9`

The first inference request in a fresh two-Mac Darkbloom session completed with
first content at **17.007461750 seconds**, inside its 18.192-second allowance.
This single development observation preserves the earlier cold-session misses;
it does not establish representative SLA compliance or explain the change.

## Workload and result

The 24 GB and 48 GB M4 Pro Macs ran the installed development build described in
the [HTTP delivery report](2026-09-15-cluster-http-delivery-recovery.md): Provider
`c4083695c07ed7da819284e48de3aeb8786940b43271fa6e974b469c26f10350`, native
worker `ffcbd7de0ccc5a8b35881f9dd5ed5b6fcb8a2f5bdc7e7b63fa1e46bd9c79bba5`.
Qwen3.5 9B 4-bit used layers 0–3 / 4–31, 512-token chunks, one-chunk lookahead,
greedy decoding, thinking disabled, MTP off and fresh request state. Inference
used Thunderbolt RDMA; the separate development Mac sent authenticated HTTP
over Tailscale to `darkbloom start --local --distributed`.

| Observation | Value |
|---|---:|
| Prompt tokens, all IDs matched by the actual Swift tokenizer | 8,192 |
| External request-send to first nonempty content | 17.007461750 s |
| First-content allowance | 18.192 s |
| First-content margin | 1.184538250 s |
| Total client time through terminal stream and body EOF | 21.130248792 s |
| Requested output tokens | 128 |
| Reported output tokens / finish | 123 / stop |
| Nonempty content events | 122 |

An independent replay of retained response bytes and their arrival offsets
reproduces the first-content time. The stream includes terminal usage, DONE
and actual body EOF. EOS shortened the output; this is not a completed
128-output-token benchmark cell. No new output-logit/state reference comparison
or engine-prefill/decode measurement was performed for this input.

Live status before the request showed both ranks ready, no active request and
all 16 admissions remaining. Provider logs contain one reservation followed by
normal terminal and retired events. There was no model warmup request in this
session. Disk caches were purged before startup, but GPU/driver caches were not
reset and earlier model work had run on these machines. The observation is a
fresh-session result, not proof of first use after boot or a clean shader cache.

## Expected failure was not exercised

The retained observer was designed to check connected deadline-error delivery.
Its client correctly returned success, while its expected-failure validator
returned nonzero because no typed deadline error occurred. The original receipt
keeps `inferenceRequestSucceeded=true`, `slaPassed=true` and
`terminalObservationQualified=false`; it is not relabelled as a failed inference
or a passing deadline-error test.

After the completed response, the parent requested an ordinary session stop.
The CLI exited zero without a forced kill. Both native workers were absent,
both ownership journals were empty and the temporary network alias was restored.
This is normal cleanup after a successful response, not autonomous cleanup of a
deadline failure. A separate controlled deadline case remains necessary.

## Resources and retained evidence

All 117/110 resource samples passed the AC, zero-swap, normal-pressure and
six-GiB actual-free-memory guards. Minimum observed free memory was
10.547714233/25.830352783 GiB on the 24/48 GB members. Sampling does not establish
continuous peak-memory bounds. No compilation or bulk transfer overlapped the
HTTP measurement.

Private evidence is retained under
`/Users/developer/DarkbloomDev/cluster-research/installed-http-deadline-terminal-observer-20260915/harness/physical-1/`.
`root-review.json` joins the independently replayed arrivals, actual client
receipt, Provider logs, tokenizer result, supervisor exit and resource samples.
The client receipt SHA-256 is
`c0795f764522cb556960bce0194a9dd62d365425f318a04504ded6e434f4157c`.
All frozen input hashes remained unchanged.

An earlier invocation stopped during Python import before creating the physical
run directory or touching the peers. The actual invocation supplied the client
module directory through `PYTHONPATH`; the frozen observer source was unchanged.
That invocation correction is retained separately.

The [execution plan](../design/distributed-cluster-execution-plan.md) still
requires representative repeated workloads, optimized solo comparisons,
startup/readiness qualification and upstream routing measurements. No MTP,
27B, Gemma, M3 Ultra or release-performance claim follows from this request.
