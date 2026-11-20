# Distributed HTTP wakeup and response lifetime correction

This additive private correction applies after the frozen
`distributed-http-terminal-delivery-draft` manifest
`8415e69acb4109936765afc3bbda129f21d063176ff51c21d61d69724de79870`.
All 33 members of that package remain unchanged. MAIN remains unchanged by this
work. Neither package has been compiled or executed.

Root source review identified two issues before integration:

1. The original body writer polled a frame slot every five milliseconds. This
   introduced avoidable delivery delay and repeated wakeups during prefill.
2. A returned response whose header write failed or whose body was discarded
   could retain the HTTP response hold, because normal `finish()` ran only in
   the body writer. A full channel close makes further delivery impossible.

The frame pump now owns one consumer continuation and one absolute probe timer.
A frame offers directly to a waiting consumer. An already queued frame wins an
expired *probe* timer; the independent visible-content deadline is still checked
by the writer. Timer/arrival/cancel resolve under one lock and resume outside it.
The consumer joins its cancelled or fired timer before another wait is admitted.
There is no per-frame polling or task-group race against a stranded stream read.
The producer remains bounded to one queued frame beyond the writer's current
frame. Cancellation resumes both sides and retains a producer task handle for
joining, even when an earlier cancellation handler already closed the pump.
The serialized writer joins the producer on both success and failure.

A full channel close now queues request cancellation, then finishes only the
HTTP response hold. A small body lifetime guard does the same when an uninvoked
body is discarded. Normal body completion calls only `finish()`; its later guard
deinitialization is idempotent. These paths cannot report native terminal usage,
retire a lease, release a device, or acknowledge an owner.

Finishing the HTTP hold can race admission. The response therefore preserves its
weak engine cancellation hook until the existing post-admission recheck. A close
between binding and insertion of the native request row cancels that row once it
exists, even if the first queued cancellation found no row. No model or lease is
captured by the production hook. Native ownership still ends only through the
existing retirement and release path.

The original fixed 500 ms serialized comment probe, byte limits, strict visible
writer-acceptance deadline, three-second delivery-only grace, terminal cause
precedence, and native/request deadlines are unchanged. Input half-close alone
is still not cancellation. The correction makes no external-receipt, physical
cancellation, latency improvement, or native cleanup qualification claim.
