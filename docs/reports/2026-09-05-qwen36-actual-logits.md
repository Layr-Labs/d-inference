# Qwen3.6 logits at the first backend difference

> Last updated: 2026-09-05 · commit `8a268ef19`

Four real-model MTP-off/cache-off runs locate the first contiguous/paged token
difference in the actual target logits. Each backend's selection agrees with its
own logits. Strict backend parity remains failed; the numerical cause and which
backend is more accurate remain unknown.

## Observations

On the M5 Max 128GiB, each backend ran with tracing disabled and then enabled at
zero-based output index 62. All four cells pass the existing integrity checks.
Within each backend, tracing preserves every prompt and emitted ID in both main
rows; both 83-token trajectories also match their historical build6 controls.
Root's strict same-build comparison additionally checks tenant, donor and recovery
outputs, with each cancellation satisfying its own prefix and retirement checks.

At the first differing decision, both arms share all 5,523 prompt IDs and 62 prior
generated IDs. Both records identify request 2, `chained_decode`, cache offset 5584,
seed token 11346, batch size 1, verification width 1 and draft depth 0. Each has one
confirmed record and zero NaN, infinity, invalid-vocabulary or omitted records.

| Backend | Logit dtype | Candidate 1928 | Candidate 6829 | Selected token |
|---|---|---:|---:|---:|
| Contiguous | BF16 | 23.5 | 23.5 | 1928 |
| Paged | BF16 | 23.5 | 23.75 | 6829 |

The independent argmax and top-two reduction agree within each backend. The
recorded Float32 bit patterns preserve the actual BF16 values. Actual query dtype
is unmeasured; equal token history does not imply equal hidden states or cached
KV. These compact observations establish neither attention accuracy nor the
source of the logit difference. The strict backend comparator still fails.

## Runtime and evidence

Build8 uses provider receipt source `82ce12db8` and diagnostic native `0103f249`.
Both release builds and nine final guard/help checks pass. Root verifies 52 build
evidence payloads, eight runtime files, actual compiler graphs of 1,252 CLI and
1,008 probe sources, 676 provider and 483 native source matches, and two
dependency-only package overlays. Probe SHA-256 is
`8e476149db74cede08a78a39d718c01f19e2d74a5654d00e2338250ba8b0eda1`;
CLI SHA-256 is `7345c5b29369a8ff168b1230254c0a164a6ccc97a0fb0baca380475acda43363`.
The Qwen model aggregate is `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed`.
Postflight verifies all 13 model files and eight runtime files unchanged; all four
output roots remain retained and the recorded postflight has no model processes.

The [manifest](evidence/qwen36-actual-logits-2026-09-05/manifest.json) and
[archive](evidence/qwen36-actual-logits-2026-09-05/payloads.tar.gz) preserve the
134-payload four-cell freeze, 52-payload build8 freeze, 37-payload reviewed plan,
their manifests, root build/plan reviews, and the independent analysis and script.
Compiled executables, metallib and model weights are excluded; their identities
remain recorded. The archive contains 230 payloads
(10,037,745 bytes); every archived member is rehashed.
Manifest SHA-256: `d697991a4a32ae3db797ff2ab5ec20273adfeec062a5e0d4383eb4fc99cf9a2a`.
Archive SHA-256: `427d10295312f2e0ac28053c0e71fc3018d5432df19e46d810552a0692df9245`.

This is an MTP-off diagnostic, without a performance claim or release waiver.
The [original regression](2026-09-05-qwen36-backend-parity-regression.md), normal-MTP
backend comparison and broader release gates remain separate. Follow the
[diagnostic procedure](../developer/test.md#prefix-cache-benchmark-validation)
when interpreting further captures.
