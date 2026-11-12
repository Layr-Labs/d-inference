# Private 27B owner native diagnostics

The new owner retains the child created by the existing factory and, after `serveConfigured` returns or throws, emits one bounded JSONL diagnostic to stderr. The record contains the actual child termination, `nativeCleanupObserved`, and the last at most 4,096 bytes of the child's existing stderr tail encoded as Base64. It does not log the request, prompt, token stream, or native stdout. No cleanup or release decision depends on publication.

Only the owner entry changes: `Sources/main.swift` adds the holder/defer and remembers the unlaunched `ClusterWorkerProcess`; `OwnerNativeDiagnostics.swift` implements the observation and best-effort write. `Qwen27BQualificationScope.swift` is exact. Removing the entry insertions restores the prior main byte-for-byte. Native arguments, runtime, protocol, stdout, owner service, lease rules, controller and four libraries are unchanged.

`bundle/` contains the new owner plus the five exact files from the fixed 27B controls bundle. Its manifest, `integration.json`, and `build-manifest.json` bind the source and dependency lineage. The new owner is an arm64 macOS 14.0 Foundation executable with only system and the four `@rpath` dependencies. The existing native worker remains external and unchanged (`a7c35b37c2ae2f80c320221ac9931bdd3f87d7e7cd67b2d5cfbc93a8eb043ad6`). Root owns any deployment, fresh configuration and physical run.

The stderr record has schema `qwen27b_owner_native_diagnostic_v1`. `termination` is null until actually observed, or identifies `launchFailed`, `exited` with status, or `signalled` with signal. A missing child stays explicit. Publication is capped at 8 KiB and 250 ms, uses nonblocking writes with SIGPIPE suppressed for the descriptor, and restores the flags it changes. A blocked or closed stderr can lose or truncate this best-effort record; absence is not evidence of a successful native startup. Existing top-level error output remains unchanged.

Validation:

- Owner-only relink passed in 0.433 s, warnings as errors, `swiftc -j 2`, against exact prebuilt modules. No module, controller, or native rebuild.
- Final seven CPU diagnostic groups passed in 0.563 s: explicit missing/unlaunched child; terminal variants; exact tail bound; one actual fabricated shell child with exit 7 and retained stderr; writable, full and closed pipes; restoration of `O_NONBLOCK` and `F_GETNOSIGPIPE`.
- An additional actual owner process received an invalid open and threw before acquiring a lease or constructing a native child. Its defer emitted exactly one no-child record; stdout stayed empty. The existing top-level error exit was preserved (signal 5). No model or network ran.
- Prior fixture failures are retained: an eight-byte literal was initially read as seven bytes; then an overly broad whole-`F_GETFL` equality assertion included a kernel status bit added by a successful write. The final test checks the two settings the writer mutates. Runtime sources and the owner binary never changed during these fixture corrections.
- Independent two-file source review is bound separately. Its original seven test bodies were read, not executed by the reviewer; final fixture corrections are author-validated.

Root should retain the owner stderr/endpoint diagnostic bytes with the enclosing native cleanup, authenticated release ACK and independent journal/process postflight. Decode `diagnosticTailBase64` only after retaining the original record. This package exposes the next run's actual failure; it does not identify the cause of the earlier zero-token failure, prove numerical correctness, or change the resource gates.
