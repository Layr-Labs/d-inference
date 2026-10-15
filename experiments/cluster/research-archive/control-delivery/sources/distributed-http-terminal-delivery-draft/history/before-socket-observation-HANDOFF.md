# Distributed HTTP terminal delivery

This private overlay addresses the role-only SSE followed by EOF failure using
the existing installed provider, engine and owner. It changes no native wire,
request deadline, resource admission, trust, device lease or retirement rule.
MAIN and all prior failure reports/fixtures were preserved.

## Source findings

* `DistributedLocalServer.beginTeardown` previously cancelled the HTTP service
  immediately. `finishTeardown` also called `EngineV2Bridge.shutdown`, which
  cancels event pumps before awaiting engine retirement. A request waiting for
  its genuine terminal/usage could therefore lose both delivery paths.
* `MLXOpenAIService.streamChatCompletionFrames` propagates a midstream error by
  throwing its sequence. The original `LocalChatUploadResponder.sseResponse`
  also throws the response body. Keeping the listener alone cannot provide an
  error envelope to the client.
* The local MultiModel initializer has no `firstContentDeadline` of its own.
  The distributed engine checks its first-token deadline while
  `completionTokens == 0`; the bridge records a first raw token and suppresses
  empty decoded text. Reasoning parsing can suppress or separate further text.
  The installed local HTTP route does not use the coordinator's meaningful-SSE
  check. A raw-token timestamp cannot establish a visible-content deadline.
* MultiModel releases its model acquisition before propagating a typed error
  to the service. Thus the acquisition pin is not a response-write receipt.

Exact input hashes are in `source-dependencies.json`; the six changed MAIN
inputs are retained byte-for-byte in `originals`.

## Changes and ordering

The installed host supplies one internal `DistributedHTTPResponses` registry to
the existing upload responder. Ordinary solo callers pass nil and keep their
original SSE helper byte-for-byte. The response handle is created only for the
distributed streaming chat path, inside normal authentication and routing.

The bridge copies the internal task-local handle before suspension. As soon as
the trusted original request instant and **actual tokenized prompt count** have
selected the absolute deadline, it binds the handle before native admission.
Binding an already-expired value throws the existing pre-content
`deadline_unreachable` refusal. There is no header-derived origin, repeated
budget interval, remote clock subtraction or new caller-facing override.

A separate timer remains armed through role-only, empty and reasoning-only
frames. Only a nonempty `delta.content` frame accepted by the local body writer
strictly before the deadline disarms it. Equality loses. An in-flight write
cannot be retracted: if its acceptance crosses expiry it does not become SLA
success, subsequent content is suppressed, and the request fails. Writer
acceptance is **not evidence of external client receipt**. Raw-token timing and
the independent engine/generation/native deadline checks remain unchanged.

Expiry requests normal generation-bound cancellation via the engine queue; it
does not block the writer or manufacture an admission failure for running work.
A repeated cancellation check immediately after synchronous admission covers a
timer firing before the engine row existed. Existing idempotent cancellation
and independent owner fences remain authoritative.

The bridge records a value-only terminal snapshot only when it consumes the
engine's actual `.finished` event. For this distributed engine that event follows
the request lease's retirement and release. EOF, a cancelled pump, response
completion, an elapsed grace, and listener exit never fabricate terminal usage.

The new response body consumes frames directly, adding no intermediate queue.
It preserves successful content bytes and delays the existing finish/DONE
frames until the outcome is known. A real terminal failure emits one bounded
JSON SSE error with a fixed message, a closed cause when present, and actual
prompt/completion `attempt_usage`, followed by DONE. Arbitrary upstream error
strings, model state and prompt contents are not included in the error.

Visible-content expiry uses the existing `deadline_unreachable` error code;
observed non-cancellation native terminal causes take precedence. A clean native
terminal with no accepted visible content under the explicit policy also cannot
satisfy that policy and emits `deadline_unreachable` with its actual usage. This
is an intentional distributed-policy behavior change. Nil-policy empty success
and ordinary solo behavior remain unchanged. Non-streaming requests retain
their existing deadline/response path in this increment.

## Teardown and bounds

Host invalidation removes discovery and closes acquisitions immediately. Owner
cancellation/fencing starts immediately, independently of the HTTP writer. An
already-active response and its bridge pump may remain for one **fixed three
second delivery-only grace**, installed once at cancellation. Repeated stop or
monitor calls cannot renew it. This permits terminal delivery after the original
deadline, never new generation or late content being counted as success.

When the response completes or the grace expires, the host cancels the listener
and bridge pump using their existing paths. It still retains the session/entry
until the existing actual cleanup, request release and owner ACK conditions.
An unresolved owner remains quarantined. The caller's bounded stop wait is
unchanged. A discarded response is cleared only after the actual HTTP service
and its child handlers return. No response hold is used as native proof.

The writer accepts at most 1 MiB per source frame and examines at most 8 MiB
per response, reserving 4 KiB for an error plus DONE. It retains at most the
existing finish frame and DONE. These are bounds on this new writer, not a new
claim about the upstream library's already-existing stream buffers. Limit or
malformed-frame refusal cancels the request and does not invent usage.

Terminal delivery is best effort within the grace. A disconnected/blocked
client, missing native proof, or cleanup taking longer than the grace may still
end with connection closure. Ownership remains held independently. The pinned
Hummingbird cancellation handler closes the channel input; its server task
joins child handlers. This patch neither changes that transport behavior nor
claims peer receipt from a successful local write.

## Integration and validation

`integration.json` maps 14 files: nine runtime files and five test/support
files. Six runtime files replace pinned MAIN inputs; three runtime files and all
five fixture files are new. SwiftPM discovers them without a Package delta.

Apply `runtime.patch` only after matching the six base hashes. Read-only
`git apply --check` passed and the original solo SSE helper remains byte-exact.
No Swift compiler, test, native execution, network request, or candidate read
was run for this overlay. Root reserved the compiler/physical test slots.

The 15 staged test methods cover role/empty/reasoning-only streams, strict
acceptance equality, a writer crossing expiry, expired/repeated binding,
actual token-count binding before reserve, expiry during admission, a blocked
writer while real engine cancellation/ACK/release progress, disconnect without
fake retirement, missing terminal proof, cause/privacy handling, successful byte
preservation, empty terminal policy, frame/stream bounds, once-bound grace,
retained owner ACK, and a real local HTTP stack using a fabricated owner.
The latter starts no native child and accesses no model payload or peer.

Root should compile/run the five `DistributedHTTP*Tests`/support files together
with the existing Distributed engine/deadline, Host, HTTP origin/auth and
observation suites. Tests are **prepared, not executed**. Independent peer
review is pending; the peer is assigned other work. Root source review and
combined Provider testing remain required before promotion.
