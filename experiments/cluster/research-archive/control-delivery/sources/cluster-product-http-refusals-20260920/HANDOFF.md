# Distributed HTTP early refusals — 2026-09-20

Source-only successor over actual qualified 2d86c6dfa94fe829c7f602f8ad38f463f58464e661ef11c7ef6a5a2372909f6a (178 tests and matching CLI passed under root). One runtime file and one new test file; no predecessor, workspace or MAIN mutation. Compiler, fixtures, network and model execution are pending.

The throwing EngineV2Bridge submission now routes every explicit pre-admission error-only exit through rejectBeforeAdmission: duplicate provider request ID, prompt+output Int overflow, shared-KV refusal, and lost ownedEngine after shutdown. A distributed HTTP response scope throws the existing mapped scheduler error after existing cleanup; an unscoped caller gets the unchanged error event and finished stream. The shutdown branch selects by the retained response scope, because its engine reference is already nil. This handle owns no native lease; the helper never creates a terminal, token usage, ACK or retirement proof. Existing deadline/cancellation precedence and admitted-generation retirement code are unchanged.

Seven staged methods cover duplicate refusal while retaining the original request until its actual fixture ACK; overflow and stopped-engine ID cleanup; zero shared-budget reservation; product factory reachability; unchanged unscoped streams; and actual loopback HTTP overflow returning status 503/JSON error with no SSE prefix, owner reservation or remaining response hold. The shared-budget test deliberately uses a custom bridge with a fabricated exhausted snapshot. It does not add parent memory authority to production distributed serving. No method has run.

Reachability audit:

| Exit | Actual route / control |
|---|---|
| Duplicate ID | Public HTTP IDs are minted internally by MultiModelBatchSchedulerEngine and the installed host has a single acquisition. Clients cannot supply these IDs. The bridge still defends collisions/reentrancy; the scoped test preserves the first admitted owner. |
| Token overflow | The actual text translation retains supplied max_tokens. Int.max plus a nonempty tokenized prompt reaches this guard before distributed workload admission. A real loopback fixture checks the pre-header mapping. |
| Shared KV | Unreachable from DistributedEngineFactory: kvBudget=nil, rate/fixed bytes=0 and both SSD caches=nil. A construction control pins this and a custom bridge tests the defensive HTTP branch. |
| ownedEngine nil | Reachable when an acquired bridge finishes shutdown before submission. The test shuts down the actual bridge then checks the scoped refusal and cleared identities. |
| Tokenization/nonthrowing wrapper | These compatibility methods are not the HTTP scheduler path. The actual scheduler tokenizes first and explicitly calls the throwing overload with firstContentDeadline; failures release the acquisition and propagate. |
| Existing do/catch | Qualified 2661 behavior already throws distributed scoped pre-admission errors after resource release. Deadline/cancellation and generation-bound retirement take precedence. It remains byte-exact here. |

LocalChatUploadResponder awaits streamChatCompletionFrames before constructing the SSE Response. That method awaits scheduler admission before creating its role-frame task. Its catch drops only the response hold; CORS maps the thrown typed error. Nonstream/batch chat collects the complete result before its JSON Response. This patch does not change admitted stream errors or authorize another workload/transport/owner.

Latest-master placement: rebase this one-file delta after transport's 1a4f2fac predecessor-only http-composed layer. All four guard bodies and the local helper stay in the same throwing overload; preserve cc225365 frameGenerationErrors policy and unrelated page/context fields. Build/composition.json is the exact old-base guard, not authority to accept an arbitrary merged tree. Root must produce a separate composed inventory before qualification on latest master.
