# Small warmup followed by exact 8192-token HTTP request

This private runner selects one frozen **512- or 1024-token warmup**, then the unchanged **8192-token workload**, through two sequential ordinary chat POSTs in one installed server session. Each requests 128 output tokens, greedy decoding, `enable_thinking:false`, and `reasoning_parser:qwen3`. It targets `/Users/developer/DarkbloomDev/installed-distributed-diagnostics-runtime-20260915` on the existing 24/48 GB pair. It changes no product startup behavior or binary.

The existing warm harness is preserved under `originals/`; `lineage.json` pins each upstream source. `integration.patch` changes only the local runner, the runtime path in `guards.py`/`supervisor.py`, and two small new input/result helpers. The monitoring, six-GiB resource guard, supervisor, remote postflight, journal retention, 600-second temporary alias lease and restoration are inherited. The runner's ownership cleanup body is byte-identical. The two missing transitive `stage_checks` files come from the corrected diagnostics harness and are explicitly retained in input pins. Their exact copies, monitor, resource helper, supervisor and physical I/O match that diagnostics harness.

The operator must already have the configured diagnostics product and these unchanged qualification tools installed on both hosts. The root agent owns deployment, source/binary/config binding, resource preparation, physical execution and recovery. No such action was performed for this handoff.

## Exact inputs and measurement

`warmup_inputs.py` verifies the frozen small-prompt manifest, original long-prompt manifest, selected plaintext/rendered/ID/request bytes, and frozen normal-client manifest plus all five client modules. Unsupported geometry or changed bytes refuse before any remote action. The CLI cannot substitute arbitrary prompts. The small prompt manifest is `eeac9a84049d4d5f441fcf46d26d5bb839f7e9758cd1f6600309ae5fb0890770`; the original 8192 prompt manifest remains `5d97049c6998aaab9f1e85c3a56ab079642227f3d724e0e56c283fe6f3a2a240`.

Both `/tokenize` preflights are mandatory, outside client timing and without generation. Every saved token ID must match; counts must be 512 or 1024 for warmup and 8192 for measurement. The warmup preflight is retained in `warmup-tokenizer/`; the existing measured preflight remains at the result root. Two 15-second absolute preflight bounds do not extend the owner lifetime. The original per-client 90-second absolute deadline, 100-second subprocess bound, 300-second native lifetime, 325-second supervisor deadline and 420-second ownership observation cutoff remain unchanged. Expiry/refusal fails the attempt; there is no reload, retry, lifetime reset or automatic rotation between requests.

The complete original request, SSE bytes, arrivals and normal-client receipt remain in `warmup-client/` and `client/`. The measured request starts only after the warmup's complete terminal receipt has passed the eligibility gate. Server usage must report the exact declared warmup input and, after measurement, exactly 8192 inputs. The product owns fresh per-request state; this harness does not independently inspect native state or numerical correctness. HTTP completion does not independently prove bilateral retirement. Existing postflight process/journal checks still govern final cleanup.

## EOS and outcome semantics

The source-counted completion usage includes an EOS/stop token even when that token adds no visible text. `accounting-source.json` identifies the current source that increments completion count before stop handling and rejects a zero-token stop. Therefore warmup requires `finish_reason:stop` with **1…128** reported outputs, or `length` with **exactly128**. A zero-output terminal never qualifies. No actual EOS token ID is inferred from SSE fragments.

Warmup eligibility requires a complete captured HTTP200 terminal stream, usage, `[DONE]`, exact input hash/settings/counts, consistent normal-client exit and no transport/stream/capture/cleanup error. A complete `stop` with no visible content can be eligible, while its original `no_content` receipt and failed content SLA remain unchanged. Likewise an otherwise valid complete response that missed its content deadline may be eligible; its SLA failure is retained. Neither case is promoted to a normal HTTP success. Other client failures abort before the measured POST.

`completed` describes successful completion of this warmup-eligibility/measurement/cleanup experiment. `normalHTTPRequestsAllPassed` separately requires both unchanged normal clients to return0; each original client status, exit, usage and content SLA remains explicit. Thus the experiment can complete while its warmup normal-client result remains failed. The measured request must still pass the unchanged normal client's external content deadline. No representative workload, causal speedup, numerical equivalence, or product warmup qualification is claimed.

## Validation and commands

`checks-1` retains an actual Python invocation: **18 tests passed**, including five mocked orchestration scenarios and the unchanged client parser used with fabricated events. The checks cover short EOS usage, zero-output rejection, missing/malformed usage, incomplete streams, timeout/cleanup failures, retained no-content/SLA failures, failed warmup preventing measurement, and exact measured input count. Ownership/HTTP adapters are mocked; no process, socket, SSH, model, GPU or compiler is exercised. `source-checks.json` records16 parsed Python files, exact cleanup comparison and source pins.

After root review and resource preparation, run either command. Each requires a new attempt number and creates a new private output directory; use both sequentially only under root coordination.

```sh
/usr/bin/python3 -B \
  /Users/developer/DarkbloomDev/cluster-research/installed-product-small-warm-http-qualification-20260915/run.py \
  --attempt 1 --warmup-tokens 512 \
  --client /Users/developer/DarkbloomDev/cluster-research/installed-http-client-draft-20260915/client.py

/usr/bin/python3 -B \
  /Users/developer/DarkbloomDev/cluster-research/installed-product-small-warm-http-qualification-20260915/run.py \
  --attempt 2 --warmup-tokens 1024 \
  --client /Users/developer/DarkbloomDev/cluster-research/installed-http-client-draft-20260915/client.py
```

These runs would observe whether a bounded preceding request correlates with the subsequent cold-miss behavior. One run does not establish that kernel warming caused an improvement. Existing cold/warm physical artifacts are untouched.
