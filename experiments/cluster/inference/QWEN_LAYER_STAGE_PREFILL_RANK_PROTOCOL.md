# Bounded two-rank prefill protocol

> Last updated: 2026-09-14 · commit `e4df336bc`

The implemented `qwen-layer-stage-prefill-rank-check` mode runs one verified dense
Qwen layer stage per process. Version **3**, flow
**`bounded_prefill_measurement_v1`**, adds fresh-state start admission and actual
first-target-token return to the contiguous layer pipeline. It remains a
**loopback-only diagnostic**, with `throughputMeasurementValid=false`.

**Validation status:** the canonical build passed. The 22-record adapter check
passed, including rank admission (6 accepted / 18 rejected cases) and v3 wire
checks (10 accepted / 88 rejected cases). Both policies then passed the
[registered 9B two-process validation](QWEN_LAYER_STAGE_PREFILL_RANK_VALIDATION.md)
on one 24 GiB M4 Pro. That bounded result includes independent final-evidence
and trace checks; it establishes no acceleration or physical transfer performance.

## Admission and start

Both processes load their verified compact stages and prepare the same fixed
input IDs before readiness. The agreement binds epoch, request UUID/spec, prompt
hash, source artifact/configuration/storage/plan, both stage identities and compact
configurations, native transformation, hidden width, residual/logit dtypes, and
selection policy. Logit dtype must be independently qualified; it is not inferred
from an incoming packet. The agreement also binds one scheduling policy:
`serial_v1` or `prompt_lookahead_one_v1`.

Readiness exchanges and validates the agreement digest through completed P2P IO;
a ready log record alone does not open the start gate. Rank zero reads its clock
immediately before sending the validated start packet. Each rank constructs its
fresh compute context only after its start send/receive completes. Initial
committed tokens and frames must both be zero. Model loading, prepared-token
distribution and readiness are outside this interval; fresh native request state
is inside it.

Admission is batch one, **1–128 prompt tokens, chunk size 1–32, one output and no
teacher tokens**. It requires an explicit policy, qualified native logit dtype,
fresh epoch, verified artifact, `cbv2-contiguous`, one repetition, no warmup and a
bounded deadline. Decode continuation and production distributed serving are not
enabled by this mode.

## Same wire, different preparation order

Both policies use the same v3 envelope, native payload and
**ready → received → consumed** acknowledgements. V1/v2 flows cannot enter this
protocol. Packet bounds are 8 KiB for start, 16 KiB for a boundary envelope and
4 KiB for token return. Original JSON is scanned for duplicate keys and invalid
integer syntax before closed-schema validation. Receive geometry comes entirely
from the locally admitted request; received dimensions never authorize allocation.

```mermaid
sequenceDiagram
    participant A as Rank zero
    participant B as Rank one
    A->>B: Loaded-source/request/policy readiness digest
    B->>A: Matching readiness digest
    Note over A: Record start clock
    A->>B: Validated v3 start
    Note over A,B: Construct fresh request state
    loop Agreed prompt microchunks
        A->>B: Boundary envelope
        B->>A: Ready ACK
        A->>B: Native residual
        B->>A: Received ACK after ownership/hash validation
        Note over A: Release sent residual; optional next prompt preparation
        Note over B: Consume, evaluate roots, commit; select on final frame
        B->>A: Consumed ACK after original-wrapper release
    end
    B->>A: Selected target token bound to final envelope
    Note over A: Validate token and final consumed; record stop clock
    A->>B: Post-stop release ACK
    Note over A,B: Final diagnostics and request retirement
```

Serial drains consumed before preparing the next chunk. Lookahead may prepare
exactly one next prompt chunk after received ACK and source-wrapper release, then
must drain the prior consumed ACK before sending another header. It retains at
most one prepared native residual and one CPU-only pending ticket. For 65 tokens
with chunk size 32, there are three frames and two permitted lookahead preparations.
Each process still has one synchronous MLX owner; this diagram and the action
counts establish permitted order, **not measured GPU overlap**.

## Token completion and diagnostic clock

Rank one validates its actual commit and performs native, uncast full-row argmax
with a finite-logit guard on the final frame. It constructs the token packet
before final consumed ACK. The packet binds agreement/request, final frame and
frontier, exact final-envelope SHA, consumer identity, vocabulary, ordinal zero,
selection policy and selected token. A consumed ACK alone supplies no token.

Rank zero stops only after final consumed ACK **and** the selected token packet
have been validated. It then sends post-stop release; rank one waits for that
release before diagnostics or teardown. This prevents rank-one teardown from
entering an interval that claims to exclude it.

Only rank zero reports `DispatchTime.uptimeNanoseconds`. Start, stop,
`elapsedNanoseconds` and `postStopThroughRequestCloseNanoseconds` are exact
**UInt64 JSON integers**. Consumers must preserve integer precision rather than
rounding absolute uptime through floating-point JSON numbers. Elapsed is computed
by integer subtraction after monotonicity checks; the displayed
`promptTokensPerFirstTokenSecond` is a derived Double diagnostic, not qualified TPS.
No rank-one timestamp is subtracted from rank zero's clock.

The interval includes start IO/validation, fresh state, all microchunks,
fill/drain, native compute/evaluation/commit, retained residual hashes/copies and
CPU/GPU fences, bounded trace/envelope bookkeeping, final norm/head, selection,
scalar readback and token return. It excludes post-stop ACK, final diagnostic
captures and request close. The separate post-stop duration extends through rank
zero's request close; it does not include later model release/cache clearing or
report serialization.

After release, each rank captures one final state snapshot. Rank one also copies
and hashes its final native vocabulary row. Reports export state metadata/SHA,
logit metadata/SHA, selected token, exact boundary/token JSON and bounded scalar actions;
**full candidate logit values/bytes are not exported**. There are no per-frame
state snapshots or full-logit captures. A separate auditor must compare final
evidence against the independently recorded baseline; the native report itself
keeps `modelForwardCompared=false`.

## Guarded invocation and failure

The optional repository [local stage launcher](../runtime/stage_checks/README.md)
now exposes `prefill-ranks`. Use its source/bundle/input pins, resource gates and
whole-cohort deadline rather than invoking the native mode directly. Its first
public scope is exactly **65 prompt IDs, chunk 32, output one and no teacher**;
it does not expose the native mode's broader 128/32 bounds or SSH execution.

From the repository root:

```sh
python3 experiments/cluster/run_stage_checks.py prefill-ranks \
  --release RELEASE --runtime experiments/cluster/runtime --output NEW_OUTPUT \
  --expected-binary-sha256 BINARY_SHA256 \
  --model-dir LOCAL_MODEL --artifact-aggregate-sha256 ARTIFACT_SHA256 \
  --tokens-file PROMPT_65_IDS_JSON --tokens-sha256 PROMPT_FILE_SHA256 \
  --stage-prefill-policy serial_v1 --stage-logits-dtype bfloat16 \
  --baseline-jsonl INDEPENDENT_NATIVE_BASELINE_JSONL \
  --baseline-sha256 BASELINE_FILE_SHA256 \
  --baseline-evidence-sha256 NATIVE_BASELINE_FINGERPRINT \
  --timeout-seconds 180
```

Both policy and dtype are mandatory. The other policy is
`prompt_lookahead_one_v1`; supported dtype declarations are `float16`,
`bfloat16` and `float32`. The example's BF16 declaration is checked against the
saved baseline's actual final row, not supplied as a model-wide default.
`--baseline-sha256` pins the exact JSONL bytes, while
`--baseline-evidence-sha256` pins the native `baseline.fingerprint`. Admission
recomputes that fingerprint and binds the independent baseline's source,
request history, schedule and final native dtype. The launcher checks outer
v3 agreement/completion; a separate audit must validate candidate numerics,
action/wire records and timing. Exit zero alone makes none of those claims.

The public entry has CPU/fake and saved-schema compatibility coverage. The
actual native proofs in the [pilot validation](QWEN_LAYER_STAGE_PREFILL_RANK_VALIDATION.md)
and [prospective timing diagnostic](QWEN_LAYER_STAGE_PREFILL_TIMING_DIAGNOSTIC.md)
used the separately frozen private guarded launcher; they are not native runs
of this new public entry. Its initial 6 GiB actual-free screen occurs before
artifact hashing, followed by the existing 8 GiB reclaimable, pressure and
zero-new-reported-swap gates. See the launcher documentation for their precise
scope and retained evidence.

Wrong identity/order, replay, malformed controls, failed native work, retained
original boundary wrappers or failed cleanup poison the request. Nonces bind
pending consumed tickets to their issuing transport. A pure `retire()` cannot
unblock a peer in native IO: the launcher must fence both processes, enforce its
independent deadline and preserve cleanup failures. Successful token timing does
not excuse failed retirement. Final reports require closed request state and
released models; phase/release counts remain source-bound assertions requiring
independent audit, not profiler measurements.
