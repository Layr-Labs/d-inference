# Cluster worker pipe protocol

This private overlay provides a Foundation-only Swift module, `DarkbloomClusterProtocol`, for an owner and its native worker on one Mac. It contains public value types, strict JSONL encoding/decoding, bounded incremental framing and worker-side lifecycle checks. It does not launch workers, load models, implement the authenticated peer channel or attach a live provider backend.

Run the CPU checks with `bash Tests/run.sh`. The runner builds a separate module and imports it from the checks, using Swift 6 with warnings as errors and a macOS 14 deployment target. The checks use fabricated identities and tokens plus one actual local Foundation pipe; they execute no model or GPU work.

## Wire contract

Each record has `version: 1`, a lowercase canonical UUID `membershipEpoch`, a strictly increasing `sequence` starting at zero independently in each direction, and a closed `kind`. Request records also have a lowercase canonical UUID `requestID`. Worker-wide records omit that key; `null` is not an omission. Duplicate keys, unknown keys at every level, floating-point/exponent/Boolean integer metadata, malformed UTF-8, invalid hashes, unknown enum values and trailing records are rejected.

| Owner command | Worker event | Meaning |
| --- | --- | --- |
| — | `ready` | Local loaded identity, rank, admitted profile, plan digest and conservative request capacity. |
| `reserve` | `admitted` or `refused` | Bind one fresh request and its bounded raw prompt/stop IDs, output/chunk counts, local deadline and capacity ceiling. Reserve does not start model work. |
| `start` | rank 0 `committedToken` | Begin an admitted request. Each emitted token is already committed by the generation driver. |
| rank 0 `tokenDecision` | next token or `finished` | `proceed` or `cleanStop` for the exact outstanding ordinal, before another forward. |
| `cancel` | `failed` if applicable, then `retired` | Abnormal cancellation is distinct from normal callback completion. |
| — | `finished`, then `retired` | Clean terminal reason followed by local state retirement. Finishing alone is not retirement. |
| — | `unavailable` | Invalidate local readiness immediately; it does not retire an active request. |
| `shutdown` | `shutdownComplete` | Accepted only without an active request. A local shutdown acknowledgment does not prove process exit. |

Only rank 0 publishes tokens and consumes provider token decisions. Rank 1 reports `finished` from its actual typed native result, without synthesizing a token replay. Rank 0's finish reason is checked against observed tokens and decisions in EOS, output-limit, client-stop priority. Rank 1's reason is a native assertion whose agreement remains on the peer channel.

The maximum command is 512 KiB and maximum event 16 KiB, including the single final LF. Pipe reads are at most 64 KiB; the framer retains one bounded partial record. JSON nesting is at most 16. Software ceilings are 32,768 prompt/context tokens, 4,096 outputs, 256 unique sorted stop IDs and a vocabulary of 262,144. The loaded profile may be smaller. Prompt plus requested outputs must fit context. Capacity values are positive and at most 1 PiB; these are representation ceilings, never allocation grants. The bounded replay set retains up to 4,096 request UUIDs per epoch, including refusals. The owner must rotate membership before this limit, with no active request and a new worker session.

`ClusterWorkerCodec` validates complete records. `ClusterWorkerLineDecoder` handles fragmented/coalesced bytes and becomes unusable after framing failure or EOF. `ClusterWorkerSession` validates commands at worker dispatch and events at publication on one serial executor. It is not a provider-side total-order mirror of independent pipes: a cancellation can cross an already published token. The provider adapter must track each direction's sequence and current request while handling that race explicitly.

## Deadline, retirement and ownership

`deadlineUptimeNanoseconds` is an absolute `DispatchTime.now().uptimeNanoseconds` deadline in the owner/worker's shared local clock domain, with at most one hour remaining at admission. Do not send one Mac's uptime number to another Mac. An authenticated distributed bridge must translate an agreed remaining budget into the receiving Mac's local deadline and charge elapsed dispatch time.

The session checks time at admission, start, token publication, token decisions and clean finish. It does not run a timer or interrupt native work. The pipe adapter must bound reads/writes and the synchronous per-token decision wait by this deadline; the native driver must receive its existing deadline/cancellation `check` callback. EOF, malformed input, an expired wait or cancellation throws from that callback and enters the outer owner's abnormal cleanup/fencing path. A blocked native collective still needs independently supervised process termination and reaping.

`retired(clean|cancelled|failed)` acknowledges **only this worker's actual local request-state retirement**. The worker must derive it from completed cleanup, never from receipt of a cancel command. There is deliberately no `fenced` message. The provider lease may return from `waitUntilRetired` only when both required workers acknowledge their matching request retirement or the owner independently observes their termination/fences. A worker cannot prove its own process fence. EOF, a sent cancel, a deadline, `finished`, and `shutdownComplete` cannot substitute for this evidence.

The session is a value-level ordering check, not proof that a model was loaded, that memory was admitted, that a token was computed, or that state was released. The exclusive native owner must supply those facts. Identities and plan fingerprints remain backend assertions; this module performs no artifact hashing, remote attestation or physical-link qualification.

## Hookup map

| Existing boundary | Adapter action |
| --- | --- |
| `DistributedResidentExecutionOwner.readiness()` | Aggregate both local `ready` records for the exact membership/ordered peers/profile/plan. Expose the conservative joint request budget; do not sum peer RAM. |
| `reserve(...capacityLimit:)` | Revalidate identity and dispatch one request UUID to both workers. Actual native owners admit resources before `admitted`. If either refuses or fails, retire/release any successful reservation before throwing. |
| `DistributedResidentRequestLease.start(emit:)` | Return promptly after scheduling the request executor. Send `start` only after both admissions. Use a separate serial I/O/execution queue; do not block a provider actor or hold a lock across `emit`. |
| Generation `onCommittedToken` on rank 0 | Publish token ordinal/frontier, wait only until the local deadline for its exact decision, and return `true` for `proceed` or `false` for `cleanStop`. A thrown error follows abnormal cancellation. |
| Provider `emit(.token(id))` | Return its Boolean as the matching rank 0 decision. If the callback called `cancel()`, cancellation takes priority over a normal false return. No draft/MTP tokens cross this channel. |
| Native normal result | The driver has already completed its bilateral native retirement protocol. Publish `finished`, then this worker's actual local `retired(clean)`. Rank 0 `.eos`/`.clientStop` maps to provider `.stop`; `.length` maps to `.length`. |
| Lease `cancel()` / `waitUntilRetired()` | Signal abnormal cancellation promptly, supervise the owned processes, and await both local acknowledgments or owner-observed fences. Keep the reservation until that condition holds. |
| Lease `releaseResources()` | Release exactly once after retirement; no native payload/model object enters the provider. Until actual usage telemetry exists, the lease may conservatively retain its admitted byte reservation as bytes in use. |
| Owner `shutdown()` | Retire/release leases first, request worker model shutdown, then observe owned process exit/reap. |

The native facade accepts the UUID, prompt/output/chunk/stop geometry and local deadline as values. It constructs the real generation agreement internally from its retained source/plan/build/membership and keeps model arrays private. The eventual worker entry and Swift process owner remain separate integration work; neither Python nor SSH belongs in product startup.

The JSON duplicate-key scanner derives from the existing shared runtime's `WorkerJSONScanner.swift`, retained under `originals/`. Only symbol/error names and the depth ceiling changed. No repository file is modified by this overlay.
