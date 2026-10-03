package api

// Routing v2 — W3: cold-dispatch spill + queue-before-shed wiring.
//
// Both behaviours are default-ON and reversible without a rebuild via env flags.
// They are read here (not on the Server struct) so this workstream stays
// confined to its owned files — server.go / main.go are owned by parallel
// workstreams. The flags are read per call: a feature-flag lookup is negligible
// next to the JSON-parse + crypto + DB work each request already does, and
// reading live env keeps the flags overridable in tests (t.Setenv).
//
//   - EIGENINFERENCE_QUEUE_BEFORE_SHED (default true): when the preflight would
//     429 `machine_busy` (providers exist for the model but all are at capacity),
//     route the request into the normal dispatch+queue path instead, so a slot
//     freeing — or a cold load completing — within the queue window serves it.
//     The dispatch/queue path still returns a 429 when the queue is full or the
//     wait times out (true saturation).
//   - EIGENINFERENCE_COLD_DISPATCH (default true): (1) when the preflight would
//     503 `no_provider` but an idle on-disk provider could load the model, spill
//     the request into the queue instead of shedding; and (2) on every queue
//     enqueue, proactively kick the model-swap machinery so a cold provider is
//     warmed for the queued demand without waiting for the next heartbeat.
