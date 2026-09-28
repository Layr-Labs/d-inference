# Deliberately short configured request deadline

This is a source-only proposal and two derived configuration inputs, not a runnable or physically qualified harness. No installed configuration, provider default, source, binary, network or native process was changed. The existing c408/ffcbd install and its 120-second request timeout remain unchanged. The frozen cold8K observer and its successful physical-1 remain untouched.

The smallest existing product seam is `ClusterConfiguration.requestTimeoutSeconds = 2`. The current validator accepts 1 through the capability's 300-second maximum. InstalledSession makes this the engine's generation timeout; the bridge preserves trusted HTTP receipt as origin, and `DistributedFirstTokenBudgetPolicy` clamps first-visible-content expiry to the earlier generation deadline. The deadline is not replenished after tokenization or admission. Two seconds is an intentional negative-test budget, not a new normal service policy or measured performance promise.

The two canonical inputs change only `clusterID` and `requestTimeoutSeconds` from the actual installed setup. Owner/native executable paths, binary and capability hashes, model, selected cut, lookahead schedule, trust inputs, chunk size, fixed owner lifetime, device gate and resource checks stay unchanged. `configuration-derivation.json` records both old and proposed hashes. Actual Swift configure/readback would still need to confirm the derived bytes.

## Required isolation decision

An alternate provider TOML alone cannot isolate this test. `StartCommand+Distributed.swift:12` requires its requested cluster reference to equal the installed owner's default reference. `ClusterWorkerOwnerCommand.swift:19` loads that default and intentionally accepts no remote-supplied config override. Both owners must bind the same temporary cluster ID. No HOME redirection, new environment override or weakened owner binding is proposed.

Execution therefore needs root to explicitly choose a temporary default-reference switch on both hosts: retain exact original provider bytes and expected hashes, use the existing configure command for the temporary setup only while both device journals are empty, run the single bounded test, observe real native/owner cleanup, then restore the original default references with unchanged-file guards. If changing those references even temporarily is out of scope, the present installed interface cannot run an isolated differing timeout. Adding an owner-config protocol is unnecessary for this test and is outside this proposal.

## Minimal harness derivative after that decision

Reuse the existing frozen terminal observer client unchanged: it already accepts the closed `inference_error` DTO with `safety_deadline`, retains reported `attempt_usage`, and reads through DONE and actual body EOF under the same 90-second observation bound. Preserve the original client's normal success/failure and 18.192-second external content metric. A two-second error with no content remains failed inference and failed SLA, not a successful short request.

Derive a new harness directory from the current frozen observer members, excluding physical results. Change only expected cluster/configuration bindings, its remote result-directory prefix, the strict terminal qualification function and corresponding model-free tests. Keep all remote helpers, resource/alias guards and actual-cleanup observation unchanged. Use the explicit `PYTHONPATH="$PWD"` invocation prefix from the separate import supplement.

The strict expected result should require HTTP200, no visible content, reported 8192/0 usage, exactly one supported typed terminal, DONE and EOF, client exit1, and false inference/SLA fields. The deadline timers can race, so accept either `deadline_unreachable` (HTTP cancellation wins) or `inference_error` with `safety_deadline` (engine deadline wins). Do not broaden this to arbitrary runtime/resource failure. Missing/duplicate/malformed terminals, false usage, premature EOF or normal successful output do not qualify this negative test.

Unlike the cold8K observer, this derivative must not require error arrival after 18.192 seconds. It should record the configured two-second policy separately. Client timing alone does not prove admission or its internal deadline: retain provider lifecycle records and require root's observation of reserved → deadline/cancelled terminal → retired for the same request before claiming active-work deadline cancellation. If tokenization/admission expires first or another resource guard refuses, preserve the failure but mark this specific observation unqualified.

Observe autonomous native and CLI retirement before any fallback stop. Expected runtime failure is natural Provider exit1; journal/process observations and actual endpoint ownership evidence remain distinct from response EOF. Do not restore a default pointer, claim reusable capacity or clear a journal based solely on elapsed time. A normal successful response should retain its true disposition, fail this expected-error qualification and use normal explicit cleanup.

## Source anchors

All anchors are pinned in `source-pins.json` against MAIN as read; no implementation changes are proposed.

| File and symbol | Relevance |
| --- | --- |
| `Config/ClusterConfiguration.swift`, validation at line70 | Supported timeout bounds |
| `Installed/DistributedInstalledSession.swift`, initializer at line108 | Timeout becomes the engine profile |
| `DistributedCBv2Engine.swift`, `deadlineContext` at line60 | Trusted-origin generation deadline |
| `DistributedFirstTokenBudgetPolicy.swift`, `restricting` at line23 | Visible deadline never exceeds generation deadline |
| `EngineV2Bridge+Submission.swift`, selected context at line482 | Bind before admission; pending cancellation retained |
| `DistributedPipeExecutionOwner.swift`, reserve at line64 | Same-origin remaining duration, owner lifetime and admission clamps |
| `DistributedCBv2Engine+Events.swift`, `checkDeadline` at line77 | Generation expiry selects `safetyDeadline` before the first-token branch |
| `DistributedHTTPEventStream.swift`, `failureFrame` at line29 | Actual terminal/usage, closed error shape and bounded output |
| `StartCommand+Distributed.swift` / `ClusterWorkerOwnerCommand.swift` | Fixed default-reference requirement |

No physical operation or compiler is authorized or invoked by these files. Root owns the temporary-reference decision, installed execution and restoration evidence.
