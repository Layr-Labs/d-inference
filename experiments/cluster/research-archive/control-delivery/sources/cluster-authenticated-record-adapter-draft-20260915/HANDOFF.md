# Authenticated record adapter — private source candidate

This adds a model-independent logical record transport over the existing completed point-to-point byte transfer. It is source-only at this freeze. No compiler, native/MLX execution, model, network, installed configuration or MAIN change occurred. The exact four codec files are unchanged from `cluster-authenticated-record-codec-draft-20260915` (`c206c9e0860c641de64057a48652887ed93a4737edf0a4db16a4ba4251f692ac`), whose eight CPU correctness groups passed separately. Those results do not execute these new adapter files.

The supplied session secret and transcript are inputs, not proof of verified/routable membership. Production coordinator authorization, per-native fresh key establishment, native padding safety, complete call-site routing and allocator admission remain prerequisites. Fixture-supplied keys authorize nothing in production.

## Concrete interfaces

`ClusterAuthenticatedRecordTransport(sessionKey:binding:limits:io:)` owns exactly one codec and one immutable two-rank `ClusterRecordByteIO`. Its only payload APIs are `send(_:expecting:check:)` and `receive(expecting:check:)`. It has no plaintext bypass, key reset, reconnect, reduction, retry or lease-release API. Instantiate once per freshly authorized native epoch, not once per request. All setup and request records share monotonically increasing directional sequences.

`ClusterRecordTransferExpectation(context:length:)` requires locally expected request/type/metadata and either `.exact(n)` or `.bounded(maximum:n)`. The adapter domain-binds framing mode and local length policy into the context digest; neither comes from the peer. Caller context metadata must contain only structural phase/geometry/frontier information, never token IDs, residuals, selected tokens, payload hashes or content-derived packet fingerprints. These remain inside the encrypted payload and retain their existing semantic checks.

- Exact records send/receive one combined `n + 40` byte uint8 frame. The receive allocation derives entirely from local geometry; decoding the public header happens after the completed receive. There is one P2P fence sequence per logical record, not a separate prefix transfer.
- Variable controls send 24 public prefix bytes and then ciphertext plus the 16-byte tag. Prefix parsing is unauthenticated, cap-only allocation logic. The local maximum and transport ceiling bound it before any body receive. The complete record must authenticate before any bytes return.
- Both modes preserve the exact codec header/tag. There is no separate plaintext UInt32 length transfer and no raw fallback on authentication, context, IO or cancellation failure.

`CollectiveRecordByteIO` constructs uint8 MLX frames directly from Data, reuses `Collective.sendCompleted`/`receiveCompleted`, and retains their actual C evaluation/status, CPU/GPU completion, rank/size and receive-ownership checks. It does not introduce another transport or change JACCL scheduling. Its completed send is still not an acknowledgment of peer consumption.

`CollectiveAuthenticatedRecords` provides byte and array APIs. Array calls derive a second canonical context binding from locally supplied shape and closed native dtype, preserve dtype bytes, and use the same Data/record core. On receive, `records.receive` authenticates and rechecks cancellation before `materializeCompletedBytes` is called. That utility reuses the existing checked native completion/fence helper and owned compact allocation validation. The two additive `CollectivePointToPoint` utilities also export native plaintext bytes using those exact fences; no public MLX wrapper status is substituted for the existing C checks.

The native owner remains serialized: no arbitrary model graph may run concurrently with these operations. The added array copy/reconstruction path is uncompiled and requires its own actual native dtype, ownership, numerical and cleanup tests before use. The Foundation runner deliberately excludes it.

## Failure, deadlines and ownership

The adapter uses a short lock only to guard admission/invalidation of one operation. It holds no adapter lock during crypto, IO or caller checks. Concurrent entry poisons the adapter; the original operation retains its slot until it returns. `invalidate()` never calls IO and does not wait for the peer. A blocked native backend still needs the existing independent process deadline. After IO/authentication, unchanged caller cancellation/deadline checks run before payload publication.

Any adapter error invalidates the codec and prevents another transfer. The original error is rethrown without recording inference data. Counter advancement at codec authentication/seal is distinct from peer consumption: failure after seal can consume a nonce without completing a send; failure after open can authenticate bytes without publishing them. Neither event is a retirement or lease acknowledgment. Existing request/session owners must cancel/fence and retain resources until their actual native cleanup and owner release proofs. This candidate changes no deadlines, process cleanup, ACK protocol or journal handling.

## Exact sizes and incomplete allocation qualification

`ClusterRecordTransferAccounting` exposes the logical plaintext maximum, sealed-record maximum, native frame sizes/count, variable-framing copies and codec ciphertext/tag logical bytes. The transport enforces `maximumPlaintextBytes <= maximumFrameBytes - 40`; the lower P2P hard ceiling remains 16 MiB. An exact 5 MiB payload therefore needs a 5 MiB + 40 byte frame, not a 5 MiB ceiling.

`CollectiveRecordByteIO.maximumNativeFrameAllocation` applies the existing real `Memory.allocationFootprintUpperBound` to the largest added uint8 frame. It is an added native frame bound, not total model or process capacity. Only one native IO call is outstanding in this adapter. The caller must retain the additional allowance through its actual fences/retirement, including any allowed overlap with one-chunk lookahead; existing lookahead extras are not spare encryption memory.

Host components include the source/exported or returned plaintext, assembled sealed record, codec ciphertext/tag/header objects and, in variable mode, separate prefix/body Data. The native sender additionally constructs a ciphertext MLX allocation; receiver copies the completed native ciphertext into Data before opening and constructing the ordinary residual. The public Data/CryptoKit APIs do not establish a strict bound on allocator capacities, reallocations, workspace or ARC overlap. Logical sizes and CPU latency measurements must not be turned into a fabricated complete host charge. Ready/reserve/live-check integration must add a qualified allocator/scratch policy and retain the existing original/reconstructed residual charge. Caller `check` is invoked before native allocation and around every transfer/reconstruction; it must include that future real memory admission.

`ClusterRecordTransferEnvelope` sums known worst-case directional plaintext bytes, sealed bytes, records and native calls with overflow checks. Its remaining-budget check includes the largest record and the codec's per-direction record/4 GiB limits. This is a pure observation, not atomic admission. The existing serialized session owner must account setup, controls, all possible outputs and both directions before admitting a request, and reserve the envelope alongside lifetime/quota/memory. Fresh keys/epoch require the existing drain/actual-cleanup/ACK gate; predictable exhaustion cannot be discovered halfway through an admitted request.

## Required native tail correction

The delegated source map found and the author independently confirmed a confidentiality prerequisite beneath logical records. `jaccl/mesh_impl.h::send` copies only the remaining logical bytes into a reused SharedBuffer. `send_to` then posts the whole buffer; `rdma.h::to_scatter_gather_entry` sets SGE length to `size()`. `SharedBuffer` construction uses `posix_memalign` without clearing. Thus the adapter's ciphertext-only logical frames do not prove that all physically emitted buffer-tail bytes are safe. The existing native send tail must be initialized or its transmitted length correctly limited, with matching protocol/completion tests, before encrypted RDMA qualification. No C++ modification is included here. It does not require splitting the one-frame residual path.

## Coverage and build boundary

`COVERAGE.md` binds the independent 29-source map and states exact wrapping/refusal and context requirements. Current production call sites remain unchanged and therefore plaintext: this package is not an enabled security feature. Complete required routing must cover the three ordinary readiness exchanges, residual headers/payloads, tokens, decisions, all ACKs and retirement. Raw reduction/legacy bootstrap paths must be excluded from required-encryption admission until separately protected. Coordinator authorization and local fresh-key handshake happen before protected load intent; they are not appended to the existing four-round mesh bootstrap ABI.

The Package delta adds the independent Security library/target (the exact frozen codec plus four adapter files) and makes Runtime depend on it. It changes no Provider/owner/control dependencies. Two Runtime facade/IO sources and the two-method P2P addition remain internal. No second decoder, state owner, service, journal mechanism or transport backend is introduced.

After explicit root source review and one compiler-slot grant, run only the Foundation/CryptoKit closure:

```sh
python3 -B /Users/developer/DarkbloomDev/cluster-research/cluster-authenticated-record-adapter-draft-20260915/Tests/run.py --output /Users/developer/DarkbloomDev/cluster-research/cluster-authenticated-record-adapter-checks-1-20260915
```

The direct Swift 6/warnings-as-errors command uses `-j 2`, 60-second compilation and a 10-second CPU fixture bound, exact reused owned-process cleanup, fresh output, source pins and retained stdout/stderr/receipts. Eight groups cover one-frame bidirectional transfers, two-frame bounded controls, all ten record types, malformed/tampered/truncated input, local context/length mismatch and replay, cancellation before IO/after authenticated open, invalidation/concurrent entry while IO is blocked, and overflow/session-envelope accounting. Fake byte IO is explicit: these are not JACCL, native reconstruction, production membership, encryption-at-wire or physical cleanup tests.
