# Outer resource check for the tiny native qualification

Source-only successor of a613272f, one entry file. Adds
`AttentionTargetVerificationCheck.run(check: @escaping () throws -> Void = {})`
so the parent can provide its actual resource/fault/lifetime check. Every inner
check runs native error check, then the outer check, then native error check,
then the unchanged 55-second/+64MiB/environment checks. The default preserves
the separate standalone entry source. No transaction, fixture assertion,
resource floor or build setting changes.

`@escaping` is required because existing fixture owners hold the callback while
the synchronous run is active; all are retired within this call. The new entry
does not store it globally or start an asynchronous task. The parent must keep
its resource owner alive through return. Original a613272f remains immutable.
No compiler, fixture, GPU, model or remote execution was performed.
