# Integration handoff

Apply the frozen HTTP terminal-delivery package first, then this correction.
`integration.json` binds four replaced runtime files, one new runtime helper,
and one new test file to their exact proposed/base SHA-256 values.
`correction.patch` passes read-only application checking against the frozen
base's `proposed` directory. SwiftPM discovers the new sources without a package
manifest change. No MAIN, native, library, wire, compiler, or network operation
was performed here.

Runtime changes are limited to `DistributedHTTPFramePump`,
`DistributedHTTPEventStream`, `DistributedHTTPResponse`,
`LocalChatUploadResponder`, and new `DistributedHTTPBodyLifetime`.
`CORRECTION.md` records the two review findings and the resulting admission race.

The eight new `DistributedHTTPFrameWakeupTests` methods cover:

- arrivals before and after consumer registration, including immediate wake;
- probe timeout followed by a frame, without abandoned stream reads;
- repeated same-deadline frame/probe races with exact frame/end delivery;
- cancellation of a blocked consumer and joining its producer;
- repeated arrival/cancellation races;
- rejection of a second consumer without losing the first consumer's frame;
- discarding an uninvoked response body while a real engine lease awaits ACK;
- full close after deadline binding but before native admission, followed by
  post-admission cancellation with release withheld until ACK.

The original 18 staged test methods, including real TCP full-close and valid
write-half-close cases, remain byte-exact in the frozen base. The combined suite
contains 26 proposed methods. **All are prepared, not executed.** Concurrency
race tests exercise repeated schedules; they do not constitute an exhaustive
scheduler proof. The new wakeup assertions establish notification against a
long timer, not a throughput or latency benchmark.

Root must review the final correction and run the combined Provider tests with
the existing engine, deadline, host, HTTP-origin/auth, and observation suites.
No compiler was run because root owns the integration/build schedule. Independent
peer review of this correction is pending; neither other agent reviewed it.
Preserve both frozen packages and record any compiler or test correction in a
separate follow-up rather than changing their members.
