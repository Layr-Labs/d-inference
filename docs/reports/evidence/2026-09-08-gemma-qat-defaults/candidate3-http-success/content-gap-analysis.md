# Rollout streamed-content timing

> Last updated: 2026-09-08 · commit `4ae34f033`

38/38 requests were structurally valid.

Gaps are between successive nonempty `delta.content` payloads. They exclude TTFT and post-content terminal drain. Phase aggregates exclude request(s) [0] (initial target load).

| Observed phase | Requests | Max content gap | Max TTFT | Max total |
|---|---:|---:|---:|---:|
| activation_overlap | 1 | 78.533 ms | 0.180778 s | 2.035918 s |
| active | 12 | 17.108 ms | 0.182554 s | 1.865646 s |
| waiting_metadata | 1 | 8.617 ms | 0.180238 s | 1.576680 s |
| waiting_weights | 23 | 18.744 ms | 0.183185 s | 1.980238 s |

The largest observed gap was **78.533 ms** in request 25, between monotonic 72.426390 and 72.504923. That request's TTFT was 0.180778 s and total latency 2.035918 s (216 completion tokens).

First active sample: `72.327921166`. First positive MTP counter is bracketed by `72.327921166` and `72.588907708`; overlapping request(s): [25].

Requests overlapping the first active sample are classified as `activation_overlap`, regardless of a stale `phase_at_start`. `waiting_weights` otherwise retains the runner's label and includes background preparation after download.

Successful streams and normal TTFT do not establish zero latency cost: inspect the content gaps and total latency too. No causal JIT attribution is made.

Limitations:

- Client-observed content payload spacing, not device token timing. Excludes initial wait and final drain from gaps.
- Activation is bracketed by periodic metrics observations; original phase_at_start can be stale.
- A pause near first verification does not establish JIT or another internal cause.
- Response lengths vary; raw total latency is not a matched-workload decode performance comparison.
- This single-host sequential B1 trace does not establish a fleet-wide latency bound.
