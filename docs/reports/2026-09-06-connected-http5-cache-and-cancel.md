# Connected SSD routing works; canceled settlement loses usage evidence

> Last updated: 2026-09-06 · commit `dda0b8807`

The rebuilt provider publishes a durable prefix and serves real SSD hits through
the coordinator. Qwen3.8 passes all ten cache-off cases and the first seven SSD
cases. Cancellation fails because its terminal lacks native cache usage and its
lookup receipt; recovery and sidecar-outage cases remain unrun. The strict pair
remains failed.

## Observed behavior

Both processes use build8 on the M5 Max, 128 GiB, with normal MTP, paged storage,
isolated ephemeral SSD keys and no resident prefix bank. Two providers and two
authenticated tenants share this machine. CLI SHA-256 is
`7345c5b29369a8ff168b1230254c0a164a6ccc97a0fb0baca380475acda43363`;
the exact Qwen3.8 target aggregate is
`bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463`.
The [build8 source and build provenance](2026-09-05-qwen36-actual-logits.md)
and [receipt ownership correction](2026-09-05-prefix-receipt-pump-ownership.md)
precede this execution.

The donor publishes Ready at 4,096 tokens: coordinator SSD donations and holder
count each increase from zero to one. The repeat records native SSD hit usage,
4,096 cached and saved tokens, and an accepted coordinator lookup. The separate
tenant stays cold. A continuation on provider B and subsequent original-prefix
routing also pass. Tools produce the required call and arguments; vision stays
cold. All seven completed cases match cache-off content, reasoning, decoded tool
calls, finish reasons and token usage under the unchanged paired comparator.

Repeat TTFT is 6.558 seconds cache-off and 1.897 seconds with SSD, including
146.117 milliseconds of staging. The original-prefix request after continuation
is 6.820 versus 1.886 seconds. These are individual observations inside an
incomplete pair, without a repeated-performance or release-acceptance claim.

## Cancellation failure

The canceled request delivers content, receives a correlated cancel and emits one
partial completion. Its terminal contains prompt/completion/reasoning counts but
no cache fields, and no lookup receipt appears. Coordinator lookup/hit counts
remain 6/2; zero wire events were dropped. SSD staging and projected prefill
savings are recorded, but those alone do not prove completed native adoption.

`EngineV2Bridge+Events.swift` records `EngineV2RequestUsageSignal` when the native
terminal arrives. `ProviderLoop+InferenceHandler.swift` can settle a canceled
stream before that event and read a nil lookup result. Its once-only receipt
finalizer then resolves a policy fallback without a tier or prompt anchor; the
V2 sequencer refuses that incomplete proof, and the later native result cannot
replace the finalized lookup. This source ordering explains the missing evidence;
a deterministic regression and corrected native handoff remain required.

## Package and evidence

The previous HTTP4 attempt failed before inference because packaging removed the
Go harness executable permission. HTTP5 preserves mode 0755, verifies file modes
alongside hashes, and checks execute access before expensive preflight work.
Twenty helper tests pass locally and on M5. Root independently verifies all 1,382
package payloads and 1,383 archive members, including modes and 988 current Go
source files. September 5 drafts and failures remain retained; September 6 request
dates are freshly planned and checked without a clock override.

Root rehashes both raw runs and the 177-payload failure freeze, then reruns the
unchanged comparator: it reports the failed candidate, canceled case and two
unrun cases. Runtime/model/config postflight identities match, owned processes
are retired and run roots remain retained.

The [manifest](evidence/connected-http5-cache-and-cancel-2026-09-06/manifest.json)
and [archive](evidence/connected-http5-cache-and-cancel-2026-09-06/payloads.tar.gz)
retain 182 verified payloads (10,724,475 bytes), including raw results, helper
changes/tests, execution provenance, source diagnosis and independent reviews.
Compiled binaries and weights are excluded.
Manifest SHA-256: `8d461148438a84144f410e876fa76984957d8f78957f0e7119159ea589674618`.
Archive SHA-256: `323d1664c59693363a541e54e35969e3c6bd22faa5cbdd4f207b953b66200a66`.

Other artifacts, full canceled-hit/recovery coverage, independent-machine routing,
persistent-key restart, concurrency/capacity and final release promotion remain
separate requirements.
