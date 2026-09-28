# Protected local HTTP correction — 2026-09-20

Source-only successor of `cluster-product-start-20260920` manifest
`5f91877e5cbc756e8187d7df848d7f55d58b97bcb48f39a366a373df2e9350f3`.
The original freeze and failed `Build/qualification-1/tests` remain unchanged.
That actual run compiled, executed 175 methods, and failed five assertions in
the two new HTTP methods; the other 173 passed. Its child exited 1 naturally
after 332.543 seconds, was reaped, and had no surviving process group. No model
or native GPU execution occurred.

The source trace identifies two runtime defects:

1. The host correctly resolved the protected session's stop set to empty, but
   `EngineV2Bridge.init` unconditionally added the tokenizer EOS back. The test
   tokenizer exposes EOS 99. The protected request owner's exact empty-stop
   check therefore refused even the valid P32/O2 request before reservation.
   The trusted factory now forwards an explicit already-resolved set through
   bridge construction. An empty set stays empty. The default constructor and
   factory paths retain the old model/tokenizer/extra-token union; vocabulary
   checking remains before distributed engine construction.
2. Synchronous distributed admission refusal became an error-only stream.
   HTTP headers could then say 200, while the distributed writer had no actual
   native terminal from which to produce its terminal error envelope. The new
   branch throws the existing mapped error before HTTP headers, after existing
   pre-submit resource release and only when retirement ownership was not
   transferred. Non-HTTP callers retain their existing stream error behavior.

No native terminal, usage, ACK, release or retirement evidence is synthesized.
Admitted requests keep their existing event pump, response hold and retirement
join. Cancellation and first-content errors keep their existing branches.

Four runtime files change; one test file adds three regression methods for
legacy union, exact empty registry-to-bridge propagation and vocabulary bounds.
Both original `ProtectedLocalHTTPTests` methods and their assertions are exact
unchanged inputs. They still require the real loopback HTTP request to reach
the fabricated request owner, emit two tokens, release after ACK, drain quota
without cancellation, and reject all three unsupported shapes before reserve.
The tests use fabricated ownership and are not hardware or encrypted-path proof.

The retry preserves the complete failed 13,875-entry source/dependency closure,
replaces only these four files, and exclusively creates the new test file.
The prospective map has 13,876 entries. The original matching helper is reused;
the new suite adds three methods to the original exact 175-method filter.
All 178 are required before building the matching CLI. No retry/preparation,
compiler, test, remote action, model execution or MAIN edit ran during authoring.

Root is the immediate source review gate. Optional independent review is
pending; no earlier lifecycle review is broadened to cover these changes.

## Incoming master placement

This patch is against the actual failed private base, not a pre-applied master
merge. `upstream-context.json` pins the two inspected cc225365 bridge sources.
In the later three-way composition, retain master's `pagedPageSize` and
`advertisedContextTokens` parameters and assignments, plus the private
`distributedFirstTokenBudgetPolicy`. Add the optional resolved-stop parameter
beside `eosTokenIds` and the nil-coalescing stop assignment at that same current
constructor seam. The submission hunk belongs after existing pre-submit release,
typed deadline/cancellation propagation, and before the legacy error-stream
fallback, once the private distributed/HTTP context seam has been composed.
No master source, current worktree, or active build workspace is modified here.
