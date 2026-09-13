# Rollout streamed-content timing

> Last updated: 2026-09-08 · commit `4ae34f033`

47/47 requests were structurally valid.

Gaps are between successive nonempty `delta.content` payloads. They exclude TTFT and post-content terminal drain. Phase aggregates exclude request(s) [0] (initial target load).

| Observed phase | Requests | Max content gap | Max TTFT | Max total |
|---|---:|---:|---:|---:|
| activation_overlap | 1 | 16.224 ms | 0.176592 s | 1.691519 s |
| active | 12 | 17.521 ms | 0.183190 s | 1.963215 s |
| waiting_metadata | 1 | 8.559 ms | 0.181242 s | 1.576700 s |
| waiting_weights | 32 | 18.937 ms | 0.184214 s | 2.007636 s |

The largest observed gap was **18.937 ms** in request 29, between monotonic 80.668722 and 80.687659. That request's TTFT was 0.184214 s and total latency 1.808912 s (193 completion tokens).

First active sample: `89.094246416`. First positive MTP counter is bracketed by `89.094246416` and `89.355193916`; overlapping request(s): [34].

Requests overlapping the first active sample are classified as `activation_overlap`, regardless of a stale `phase_at_start`. `waiting_weights` otherwise retains the runner's label and includes background preparation after download.

Successful streams and normal TTFT do not establish zero latency cost: inspect the content gaps and total latency too. No causal JIT attribution is made.

Limitations:

- Client-observed content payload spacing, not device token timing. Excludes initial wait and final drain from gaps.
- Activation is bracketed by periodic metrics observations; original phase_at_start can be stale.
- A pause near first verification does not establish JIT or another internal cause.
- Response lengths vary; raw total latency is not a matched-workload decode performance comparison.
- This single-host sequential B1 trace does not establish a fleet-wide latency bound.
