# Guarded remote long-solo phase request

An isolated source/fake-CPU adaptation of the frozen remote long-solo launcher.
Root owns all native builds, actual SSH, execution and later sidecar retrieval.
The original launcher folder remains unchanged.

The entry basename remains `launch_remote_long_solo.py` inside this new folder.
Only two upstream runtime files differ: the entry's description/receipt namespace
and phase-request flag; and the exact native configuration's appended option:

```text
--prefill-phase-trace-file @rank/phase-trace.json
```

The receipt kind is `remote_qwen_long_prefill_solo_phase_launcher`, with
`phase_timing_requested=true`. The native mode stays
`qwen-long-prefill-solo-check`. Existing ready/report JSONL, numerical oracle,
four native memory phases, supervision and output caps are unchanged. The option
is part of the exact staged rank configuration, its hash, and before/after checks.

## Root-only launch after native integration

```bash
python3 launch_remote_long_solo.py \
  --release <built-release-directory> --runtime <repository-runtime-directory> \
  --output <new-retained-run-directory> --host <configured-SSH-alias> \
  --remote-model-dir <registered-model-directory> \
  --remote-run-root <owned-remote-run-root> \
  --prompt-file <raw-prompt-8192.json> --long-prompt-sha256 <raw-prompt-SHA256> \
  --prompt-origin-file <retained-tokenization-receipt.json> \
  --prompt-origin-sha256 <origin-receipt-SHA256> \
  --artifact-aggregate-sha256 <registered-artifact-SHA256> \
  --expected-native-sha256 <new-phase-capable-native-SHA256> \
  --parent-timeout-seconds 330
```

The native pin is explicit; no prior executable is presumed phase-capable. The
admitted request stays 8,192/512/output-one, no teacher history, one fresh request,
no warmups, native CBv2 and the same three arithmetic environment values.
Raw prompt bytes are copied, never JSON-rewritten. The guarded worker still
removes inherited `MLX_`/`DARKBLOOM_` variables before setting admitted values.

The initial remote actual-free gate remains 6 GiB, before bundle/model reads;
post-hash estimated-reclaimable memory must be at least 8 GiB. Pressure is at
most two, reported swap must be zero, native/worker timeout is 300 seconds and
parent timeout is at most 330 seconds. Owned-run cancellation, local SSH reaping,
separate primary/cleanup/post-run failures, immutable archives and before/after
source/model/raw-input checks retain their upstream behavior.

## Sidecar scope

The launcher requests the native sidecar but does not retrieve, hash or validate
it. Successful launcher completion means the unchanged two-line outer stdout
contract passed; it does not prove the sidecar exists or qualifies its contents.
The sidecar remains under the owned remote native directory for a separate
root-controlled, bounded read-only post-run collection and CPU audit. No existing
metadata retrieval hook or output schema was widened.

Phase observations add recorder overhead and do not qualify physical transport,
GPU overlap, stable throughput or causal scheduling speedup. The independent
numerical oracle may be reused for unchanged stdout; the old provenance checker
cannot accept the new launcher namespace/configuration without an explicit
separate adaptation.

## Prospective checks

The 18 upstream fake tests are byte-identical and pass with the two new phase
tests: exact option/path binding rejects omission, redirection and duplicate
options; a complete invented run requests the sidecar while making no retrieval
claim. Process/socket entry points are blocked in the fixtures. All Python files
pass Python 3.9 syntax checks. The freeze lists the 12 exact upstream copies,
two changed runtime files and added tests/documentation. No actual SSH, native,
model payload or new candidate output was accessed.
