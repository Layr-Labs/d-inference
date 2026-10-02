# Resident prompt lookahead, disabled by default

This isolated overlay adds one optional prompt preparation slot to the current generation path. Main, worker startup, native dependencies and actual execution are untouched. Root must first qualify the existing serial O128 path. The six changed native Runtime files have not been compiled or executed against MLX; only the listed Foundation fixtures were compiled and run.

## Opt-in and compatibility

The benchmark SPI accepts `recordingReadiness(prefillPolicy: .oneChunkLookahead)` and `reserveRecording(requestID:request:prefillPolicy:)`. The selected policy and exact added allowance are retained in that actual reservation; start cannot upgrade a serial reservation. Ordinary serving and omitted benchmark arguments stay serial. No environment flag, worker CLI change or remote command has been added.

The opt-in adds `prefillSchedulingPolicy: "oneChunkLookahead"` to the generation agreement. Serial omits it and retains the old agreement bytes/hash. Both ranks must agree before native request-state construction. The result adds `prefillSchedule` only for lookahead: policy, rank, preparedAheadFrames, maximumPreparedBoundaries, pendingConsumedAtCompletion=0 and decodePrefetchCount=0. Rank0 has ceil(prompt/chunk)-1 ahead preparations and maximum1; rank1 has0/0. The new agreement changes its history/token-chain domain as intended. Compare selected IDs and state/logit bytes independently, not the serial agreement-dependent chain literal.

Arithmetic's first O128 comparator remains closed to the old serial schemas and correctly refuses these additions. A prospective lookahead derivative must require matching agreement/result policy and exact rank/count invariants; missing evidence cannot establish lookahead.

## Ownership and protocol

`sendBoundaryUntilSent` is the exact previous header/ready/payload-send prefix. It returns only after the unchanged completed C send, with a CPU ticket. Every other transport operation refuses while that ticket awaits consumed; `finishBoundaryConsumed` validates the exact fingerprint and clears it only after the unchanged ACK validation. The serial wrapper calls both consecutively. No packet kind, message order, receive operation, token/decision exchange or retirement exchange changes.

The private producer captures k's actual native commit, drops the original boundary wrapper in an inner autorelease scope and checks its weak reference before preparing k+1. It retains at most one prepared native boundary. `QwenGenerationPrefillWindow` permits preparation ahead only after completed-send credit, refuses a second slot/next send before consumed, and checks captured rather than advanced frontiers. Shared generation control remains at k until its consumed ACK. The next iteration checks the actual prepared frame and current session frontier. No final-prompt/decode prefetch exists. Failure drops the slot, poisons transport/control, retires local state and preserves the existing external peer-fence requirement.

Completed send permits source release, not peer validation/consumption. This policy therefore differs from the old experimental received-ACK lookahead point. No asynchronous model execution, extra native stream, or model work inside a transport operation/check callback is introduced. All current native completion fences, model evaluations, hash/readback checks and numerical source bodies remain.

## Added reservation and limits

For rank0 with more than one prompt chunk, reserve an additional allocator-bounded native residual and an additional logical residual-sized host staging allowance, plus65,536 bytes for bounded CPU packet/token/summary bookkeeping. At chunk512/hidden4096/BF16 this means4 MiB plus the actual allocator rounding for native, 4 MiB host copy, and64 KiB bookkeeping. Other ranks and one-chunk prompts reserve64 KiB bookkeeping only and acquire no prefetch allocation.

This is added to the original state/fusion plus recording capture reservation, checked against both owner and corresponding maximum readiness capacity before admission. Start rederives the additional allowance and refuses drift. Opted execution's existing250 ms live check charges original base + recording + lookahead together: actual free includes native and host increments; the allocator includes native increments. The6 GiB actual-free minimum, headroom, zero-swap, pressure/power/thermal, deadlines and cancellation checks remain unchanged.

The existing two-boundary/state reserve is retained in full. Per-process model work is still serial; earlier model/state computation completes before the next frame. The new live graph/result ownership is one prepared boundary, with the old send wrapper released first. The64 KiB bookkeeping quantity is a named bounded-value allowance for the existing <=16 KiB encoded control packet, <=512 input IDs and fixed scalar summary, not a proof of total Swift heap allocation. There are no per-chunk trace arrays or new full-vocabulary/state captures. Unknown native workspaces, allocator cache and whole-process peaks remain governed by the existing actual observations/headroom, not claimed by this ledger. Actual weak-wrapper/native allocation behavior still requires root's compiled native and O128 checks.

## Checks and promotion

`Tests/run.sh`: six Swift6 warnings-as-errors Foundation groups passed, empty stderr, using actual policy/window/allowance and existing checked-byte/error sources. They cover serial/ahead consumed-frontier equivalence, one-slot/credit/replay refusal, exact captured frontier, failure/final-frame limits and additional-capacity/overflow/rank cases. They do not execute a model or establish actual storage lifetime.

`Tests/compare-serial.sh`: three saved-original serial agreement/result byte comparisons and three opt-in descriptor/hash/result cases passed, empty stderr. It compiles actual pure agreement/request/result/schedule/JSON sources and exact source-extracted identity/SHA helpers. The first comparison runner failed before compilation on Bash3 empty-array expansion; its logs remain. The only correction was the runner's default compiler flag array.

`check_source.py`:32 source checks passed. The actual source/forward/token/decision/receiver/retirement bodies and sender native prefix are unchanged. All six main bases still match their saved originals. These are text-preservation checks, not native compilation.

`runtime.patch` and `integration.json` map eight Runtime files. Do not promote automatically or replace package manifests. The benchmark-only call-site opt-in, native compile, independent source review, matching O128 numerical comparison, cleanup/cancel fixtures and measured serial/lookahead comparison remain root-owned follow-up. There is no performance claim from the CPU checks.
