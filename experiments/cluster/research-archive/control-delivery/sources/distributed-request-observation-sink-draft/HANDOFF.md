# Bounded request observation delivery

Private source overlay against the current synchronous logging implementation.
No main edits, compiler, native, model, network or physical execution occurred.
Root owns the combined Provider test run after the native build slot ends.

The engine captures `DistributedRequestObservation` values on its existing
serial queue. A separate serial sink holds at most 64 pending values and one
callback in flight. It never captures the request state, lease or model in its
queued work, and invokes the callback outside its lock. A stalled callback can
retain only this bounded instrumentation work; cancellation and retirement do
not wait for callback delivery.

Overflow drops the newest observation and increments a cumulative `UInt64`
counter, saturating at `UInt64.max`. Every delivered value receives the count
observed when dequeued, and logging emits `dropped_observations`. If a callback
never returns, no later delivery can occur; the sink retains its bounded pending
values and loss count. It does not claim complete logs in that case.

Terminal observation enqueue now follows internal deadline-task cancellation
and `lease.cancel()` when needed. Retirement-latch completion precedes retired
observation enqueue. Existing wire, native deadlines, lease acknowledgement,
resource release and first-failure precedence are unchanged.

The three existing timing/order/privacy tests now await asynchronous delivery.
Two new tests block the first callback on its own queue and verify:

- First-token deadline cancellation progresses while the callback remains
  blocked; no resource release happens before the fabricated actual lease ACK;
  ACK, release, stream completion and shutdown then finish without that callback.
- Seventy additional observations leave exactly 64 pending and six dropped;
  terminal/retired events obey the same bound, raising the loss count to eight.
  After unblocking, subsequent delivered values report that cumulative loss.

The callback wait is bounded only in the fixture, with an explicit still-blocked
assertion before/after lifecycle progress. Production never assumes it returns.
All new tests are source-only so far. Suggested root selection:

```sh
cd provider-swift
swift test --jobs 2 --filter DistributedRequestObservation
```

`integration.json` contains exact destination/base/proposed hashes; the patch
read-only applies against those bases. No Package manifest change is needed.
The original finding is preserved separately in
`distributed-request-observation-review-draft/initial-source-review.json`
(SHA-256 `c961fd95d61f2cef876b6c8cfa6dab33e330efbceba102919b9a4d11f2528d48`).
Independent correction review is pending; root will review before integration.

Timing remains provider-local: the first-token phase is the first committed
token, possibly empty text, not external first-content TTFT. No prompt, token
ID/text, arbitrary error string, remote clock or credential is added to logs.
