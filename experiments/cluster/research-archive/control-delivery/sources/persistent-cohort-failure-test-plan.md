# Persistent cohort adversarial CPU tests

These tests use the actual supervisor/cohort implementation and real local child processes, with an executable Python fixture in place of MLX. They establish protocol/process ownership behavior, not inference correctness or transport speed. The fixture spawns an independently observable descendant that ignores SIGTERM, retains a per-rank load/request audit log outside protocol stdout, and supports controlled faults on exactly one rank.

| Case | Required observable evidence |
|---|---|
| A/B/A requests | Same two native PIDs and epoch for all requests; exactly one load record per rank; A repeats produce the same deterministic output and B differs; all three request IDs appear once in order per rank. |
| One rank disagrees on a token | No callback for the mismatched step; infer fails; both process groups retire; epoch becomes invalid; subsequent infer never reaches either worker. |
| Wrong request ID or epoch | Even syntactically valid progress/completion is rejected before user output; both workers retire and session cannot restart. |
| EOF or crash while active | A marker proves both ranks entered the request before fault injection; surviving peer and failed leader's stubborn descendant both stop within the deadline. |
| Silent active worker / deadline | Cancellation is cohort-wide, infer exits with a timeout/failure, no live descendant remains, epoch cannot be reused. |
| Explicit cancel during active inference | Cancel from another thread after observing the active marker; infer unblocks; no further callbacks; repeated cancel/close is idempotent; cleanup retains process ownership until exit. |
| Unresponsive shutdown | An idle worker ignoring shutdown and SIGTERM is forcibly retired within a bounded close; its descendant is also gone. |
| Caller callback throws | Callback exception cannot leave the other rank blocked waiting for the next command; no subsequent request accepted. |
| Concurrent infer | Second infer is rejected locally while first is active; it does not enter either worker's request log; the first request remains cancellable. |
| Corrupt bundle/startup mismatch | Failure occurs before any inference command; an already-started peer and its descendants are retired. |

Every failure test attempts reuse and checks that the fixture request log did not grow. Cleanup assertions inspect actual process status (terminated or zombie is not running), not just Python process-handle return codes. A test cleanup backstop prevents leaked fixture processes when an assertion fails; assertions run before that backstop so it cannot hide supervisor failures.

Implemented result: `python3 -m unittest -v test_persistent_failures` passed all 15 test methods (including grouped identity faults) in 17.448 seconds. The tests use the real snapshot/staging/rank supervisor and native subprocess pipes, with a CPU fixture executable. They additionally cover idle native exit, stale epoch/sequence, and all streamed tokens without peer completion. Every runtime failure checks process death before fallback cleanup and rejects later start/infer on that object. Source fingerprints are recorded in `persistent-cohort-cpu-lifecycle-result.json`. This is lifecycle evidence only; it does not establish model cache isolation, numerical parity, GPU cleanup, remote cleanup, or throughput.
