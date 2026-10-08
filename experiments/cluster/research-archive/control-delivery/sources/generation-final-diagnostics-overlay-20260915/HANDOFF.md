# Final generation diagnostics — 2026-09-15

This private overlay adds opt-in final-state/final-logit evidence to the existing
serial generation driver. It does not alter the serving facade or its return
type, loader, generation math, token/decision protocol, or retirement exchange.
The ordinary `runQwenLayerStageGenerationRequest` calls the same core with
`diagnostics: nil`. No diagnostic capture is enabled by default.

`recordQwenLayerStageGenerationRequest(loaded:profile:plan:agreement:collective:
requestAllowance:onCommittedToken:check:)` is the internal diagnostic entry.
The caller retains the existing exclusive resident reservation, model/source/
arithmetic checks, request deadline, cancellation, and peer-fencing duties.
`profile` is the already-admitted registered profile from the loaded stage.
The driver still invokes the token callback only on rank0. False requests a clean
client stop; thrown errors remain failures.

After both final decision ACKs, rank1 copies its complete native final row using
the unchanged `QwenRecordedLogits` implementation and checks its first maximum
against the agreed target token. Rank0 records no logits. Before `finishGeneration`
retires local request state, each rank uses the existing snapshot and exact
`QwenLayerStageRankStateCapture` validator, retaining metadata/hashes with no raw
state bytes. Only after the unchanged bilateral retirement exchange and native
error checks does the wrapper return a CPU value. No model, session, MLXArray or
file escapes. Failure discards captures and follows local cancellation; a thrown
request still requires the owner to cancel/fence its peer before claiming retirement.
Recorded native errors take precedence over secondary Swift errors before cleanup.

The extra admission has no permissive callback or byte override. It matches the
private-initialized registered profile to the actual loaded config/artifact/dtype
and rebuilt cut Plan, rederives the existing request allowance using actual
allocator bounds for this rank, `P+O`, and `min(chunk,P)`, and requires equality
with all three fields of the owner's reservation. An output1 or fabricated
byte-only allowance cannot substitute. The current facade remains registered9B
only; this overlay does not widen that scope.

For rank1, H is the separately owned native-byte CPU row plus its Float32 values;
A is the sum of independently bounded native row and Float32 conversion arrays.
For the 248320-vocabulary BF16 profile, H is 1,489,920 bytes; A is dynamic and uses
the actual allocator and maximum-buffer checks. Rank0 has H=A=0. If B is the
unchanged state/fusion request reserve, the diagnostic live gate requires
`actualFree >= max(6 GiB, B + H + A + 4 GiB)` and
`allocatorLimit >= active + cache + B + A + 2 GiB`.
The base already includes its conservative largest host state-copy component;
these row terms are additional. Direct OS zero-swap/pressure/free checks and AC/
thermal checks run at entry and at both sides of each capture. Other observations
are throttled to at least 250ms between checks; this is not a maximum sampling-gap
guarantee during blocked native work. The existing owner deadline and external
process fencing remain necessary. No global memory setting changes. Named reserves and
headroom are operational policy, not a whole-process peak proof; serialization
and metadata overhead are not individually bounded. `encoded()` caps each final
record at 16 MiB after encoding; it is not an allocator bound.

`integration.json` maps nine files into `libs/darkbloom-cluster/Sources/
DarkbloomClusterRuntime`: replace only the driver and add the other eight. The
logit helper is copied unchanged; `QwenRecordedState` and rank capture are exact
type extractions from the frozen harness. Do not also compile their original
enclosing harness files in this module. Session, selection, transport, serving
result and the seven-file facade remain unchanged. Native typecheck is pending.

The minimal future owner hookup is inside the existing locked/lifecycle-owned
`QwenResidentRuntime.start` scope: pass `stage.loaded`, `stage.profile`, the existing
Plan/agreement/collective, and `reserved.allowance` to this entry only for an
explicit diagnostic operation. Keep serving's existing call unchanged. Publish
the CPU evidence only after the owner's lifecycle/autorelease scope also returns.
No public serving API or pipe event is added here; root owns that integration.

To compare with the separate full-generation reference, require identical actual
selected token histories, clean reasons, frame counts and committed frontiers.
For P8192/C512/O128 without early stop, that is 143 frames, capacity8320 and
frontier8319. Bind both records' agreement/source/Plan/build/policy identities.
Join their disjoint, complete global state-entry sets before comparing to the full
reference; a local stage hash is not a whole-model hash. Compare rank1's final
logit shape/dtype/native-byte hash and full Float32 values (or use the reused
in-process exact-byte comparison). This captures final logits, not every
intermediate vocabulary row, and does not itself perform a numerical comparison.
Diagnostic timings are not throughput or external TTFT measurements.
Fresh reference/candidate UUIDs may differ; compare their actual input geometry
and histories rather than equating independently UUID-bound request fingerprints.

Validation: nine-source standalone Swift6 `-warnings-as-errors` fixture passed
20 accepted/28 rejected cases (1.988s compile, .312s run; empty stderr). It exercises
the actual pure budget/completion predicates with invented arrays/allocator
closures, not the live gate or bilateral transport. All nine runtime sources
syntax-parse. The source checker verifies upstream pins, exact helper extraction,
and the unchanged normal driver core after removing the two optional hooks.
No model payload, GPU, SSH, native runtime compilation, or physical execution.
