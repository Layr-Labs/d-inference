# Connected cold-8K terminal observation

This separate client/harness observes delivery of a failed request. It does not change Provider/native sources, the normal client, SLA, prompt, generation settings, deadlines or native admission. All code is private; no remote, compiler, model or physical request was executed by the author.

The normal client already receives `--timeout 90` from its harness and computes the 10 seconds + 1 ms/input-token SLA afterward. Its early error exit comes from `client_observation.py:15`, which throws on an SSE error object. This derivative accepts only the current closed `DistributedHTTPEventStream.failureFrame` error + `attempt_usage` DTO, retains it, and reads through `[DONE]` and actual HTTP body EOF. Native source pins are in `native-dto-source-pins.json`. The inherited parser retains raw bytes/arrival times, ignores comment probes, rejects data after DONE and enforces the same frame/stream/line bounds. No error message is evaluated as code or used as an instruction.

`terminal_observation.py` records the typed error separately from normal completion usage. A typed error always produces client exit **1**, failed request status, and false SLA success. Missing/duplicate/unknown terminal, false/noninteger usage, missing DONE and missing EOF do not qualify. A well-formed failure with no EOF remains bounded by the client's existing absolute timer. Normal responses retain the original success/deadline-miss behavior; an unexpected successful request is reported honestly and does not qualify this expected-failure observation.

## Root-run command

Run from this directory only after the compiler, file copies, other physical requests and previous ownership cleanup are terminal:

```sh
/usr/bin/python3 -B harness/run.py --attempt 1 \
  --prompt-file ../installed-http-long-prompts-20260915/fixtures/prompt-8192.txt \
  --declared-prompt-tokens 8192 \
  --rendered-prompt ../installed-http-long-prompts-20260915/fixtures/prompt-8192.rendered.txt \
  --expected-token-ids ../installed-http-long-prompts-20260915/fixtures/prompt-8192.ids.json \
  --client client.py
```

The harness passes the unchanged **90-second** client observation limit and **100-second** parent command bound. The content SLA remains **18.192 seconds**, derived from 8192 tokens, never 90 seconds. The optional standalone client timeout API is inherited; this fixed physical invocation is 90 seconds. Input/rendered/token-ID hashes are in `prompt-pins.json`; the ID list has exactly 8192 entries. Existing tokenizer verification runs before the one chat request. “Cold” here means the first generation in a fresh resident session; this harness does not purge OS caches or alter hardware state.

Local output is `harness/physical-1`; the remote leader directory is `.../installed-distributed-http-delivery-runtime-20260915/qualification/terminal-attempt1`. Fresh attempt IDs are required; no overwrite or automatic journal recovery. `bindings.json` pins the same installed c408 Provider, ffcbd native, capability, configuration and explicit lookahead used by the frozen normal recovery harness. Runtime installation verification remains root's deployment evidence. The five remote helpers exactly match the already-installed normal/cancellation set (`remote-helpers.json`); this derivative needs no new remote helper.

## Cleanup and qualification

Before the request, the unchanged status validator requires actual authenticated two-rank readiness, fresh epoch/nonce and exact canonical leader configuration. The failure contract requires HTTP200, closed typed deadline error (`deadline_unreachable`, or `inference_error` with `prefill_stall`), reported `attempt_usage` 8192/0, no visible content, complete DONE+EOF and false SLA success. It records whether the error arrived at or after the original content cutoff. An earlier failure remains a failed request but does not qualify the requested beyond-cutoff observation.

The client records its post-EOF close using `clock_gettime(CLOCK_MONOTONIC)`. The harness reuses the exact cancellation cleanup observer and its same-Mac OS-clock contract; no remote uptime is compared to local time. During the default 30-second cleanup window, no normal stop/EOF is sent to the supervisor. Resource guards remain active and disqualify autonomous cleanup if they intervene. The unchanged fallback only runs after that window or an earlier invalid/error path. Qualification requires actual native/CLI process absence and empty journals on both hosts, plus the supervisor's **natural Provider exit1** with no forced kill. EOF, error delivery, elapsed time and CLI exit alone do not prove native cleanup or bilateral acknowledgment.

The result separates `terminalObservationQualified` from `inferenceRequestSucceeded` and `slaPassed`. The harness may exit0 for a completely observed, autonomously cleaned-up expected failure; its inference/SLA fields remain false. Unexpected normal success stays success in those fields while the failure observation is unqualified. This is not cancellation qualification, independent ACK proof, tensor correctness, representative performance or OpenRouter qualification.

## Validation and preserved history

`checks-3` passes all **32** model-free checks in **6.238 seconds**: 13 original client cases, six unchanged cleanup cases and 13 new terminal/reporting cases. Tests use fabricated values, fake localhost HTTP and one local OS-clock child. No physical endpoint was contacted. All 23 current Python source/test files parse as Python3.9.

`checks-1` is preserved (29/31 passed): the inherited precise clock fixture needed one extra EOF timestamp, and the first no-EOF test allowed an idle socket/SIGALRM race. The fixture-only correction appends one tick and uses bounded comment trickles to test the absolute deadline deterministically; no SLA assertion was relaxed. `checks-2` passed31. A final reporting follow-up prevents an unexpected normal response from being mislabeled failed inference and rejects bool-as-exit-code; exact checks-2 originals and delta are retained. Twelve of the 13 original client test methods remain AST-identical; only the precise clock fixture gains the EOF tick. Client input, timeout, SSE parser, content SLA logic, all remote helpers and autonomous cleanup observer are unchanged.

`runtime.patch` shows the two inherited runtime edits; `terminal_observation.py` and `harness/terminal_contract.py` are the two new pure modules. `lineage.json` pins every reused source. Normal harness manifest e4bb4860…bf457 is preserved and verified. Root/independent source review and physical observation are separate and pending at this freeze.
