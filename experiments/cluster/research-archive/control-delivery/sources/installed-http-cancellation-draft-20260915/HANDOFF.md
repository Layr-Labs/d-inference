# Installed HTTP cancellation qualification

Private derivative, 2026-09-15. No MAIN edits, remote commands, model calls or
native builds were performed. Root owns deployment and all physical runs.

`cancel_client.py` copies the frozen client's exact bounded input, strict SSE,
content observation and absolute-timeout helpers. It sends the same supported
greedy Qwen request with `enable_thinking:false`, `reasoning_parser:qwen3`, and
128 requested output tokens. The bearer token is only read from an owned0600
file; it is absent from command arguments and saved request/receipt data.

- `before-content`: after `HTTPConnection.request` returns, arm the declared
  delay (default0.5s). Shutdown the actual socket even while waiting for headers
  or a partial SSE line. Any observed content before this trigger fails the
  requested phase. “Before content” is the client's observation, not proof that
  a server has done no work or sent no buffered bytes.
- `after-two-content`: shutdown immediately after the second complete SSE event
  containing nonempty `delta.content`. Role-only, reasoning-only and empty
  content events do not count. These are two content fragments, not two tokens.

The socket object is retained across HTTP connection detachment. The timer uses
`shutdown(SHUT_RDWR)` to interrupt reads; it is joined before response/connection
close. Each close is attempted independently. Absolute request timeout, malformed
identity/usage, early normal finish, capture failure, cleanup failure and an
operator interruption remain failures. Missing terminal usage is expected only
for the intended partial disconnect; no normal-completion or SLA pass is emitted.

Artifacts are exact retained SSE bytes/arrival timestamps, parsed content and
reasoning prefixes, supported request JSON, and a receipt. Buffered/unread bytes
are not claimed captured. Origin is immediately before HTTP POST; the timed
disconnect delay begins separately after POST submission. Raw capture<=8MiB,
<=4096 retained lines, each<=1MiB; decoded prefixes together<=512KiB. The client
absolute timer covers the request; the runner's100s subprocess timeout also
bounds local cleanup/receipt publication.

## Runner and physical procedure

`harness/run.py` is a narrow derivative of the current reviewed installed-product
harness. It uses the same deployed supervisor, monitors,600s alias lease, actual
process/journal observations,420s owned-lifetime cleanup cutoff and private token
handling. The only physical-IO change adds a caller-tightened postflight timeout.

After the client has positively recorded the requested disconnect, the runner
leaves supervisor stdin open and sends no stop for a default30s window, measured
from the client's same-Mac monotonic connection-close instant. It samples both
nodes, retaining observations and available provider/supervisor logs. A failed or
late sample cannot prove absence. Resource monitors remain active; any guard
stop makes autonomous cleanup unqualified. A successful observation needs both
nodes' matching process-name set empty and both persistent journals zero, within
the window and without harness intervention. These process-name observations are
conservative and do not replace native retirement ACKs.

Only after observation finishes does the original independent cleanup fallback
send stop. The final result also requires the launched supervisor's natural
exit, no forced kill, explicit product exit0 or1 matching supervisor status,
postflight absence/zero journals, clean monitor/alias shutdown and unchanged
source pins. Product exit1 is retained because cancellation may deliberately
poison and tear down the installed session. Signal crashes, SSH errors and forced
stops do not pass. A clean fallback cannot turn a failed autonomous observation
into a pass. The receipt does not independently prove the server's causal reason
for teardown; root must inspect corresponding provider logs.

Root can choose unused attempt numbers and run, after the usual resource gates:

```sh
/usr/bin/python3 -B /Users/developer/DarkbloomDev/cluster-research/installed-http-cancellation-draft-20260915/harness/run.py \
  --attempt 41 --mode before-content --cancel-after-seconds 0.5 \
  --self-retirement-seconds 30 \
  --client /Users/developer/DarkbloomDev/cluster-research/installed-http-cancellation-draft-20260915/cancel_client.py \
  --prompt-file /Users/developer/DarkbloomDev/cluster-research/installed-http-long-prompts-20260915/fixtures/prompt-8192.txt \
  --declared-prompt-tokens 8192
```

Use a separate unused attempt and `--mode after-two-content` for the second case.
Optional `--rendered-prompt`/`--expected-token-ids` preserve the existing untimed
Swift tokenizer preflight. Remote output directories are named
`qualification/cancel-MODE-attemptN`; all original attempts remain untouched.

After each cancellation case, root must independently confirm final journals,
process absence and restored aliases, then use the normal frozen client/harness
to start a **fresh installed session** and complete a normal request. This draft
does not automatically clear journals, reload, retry, rotate membership or run
that recovery request. `recoveryRequestQualified` stays false until separately
retained real evidence exists.

## Validation and lineage

`checks-2/execution.json`: Python3.9.6,18/18 checks passed in0.755s,13 actual
loopback-HTTP cases plus5 deterministic observation cases. Source AST parsing
passed for18 inputs; source pins stayed unchanged. Tests cover real socket
closure before headers/through partial SSE, precise content-fragment counting,
phase miss, normal early finish, bad identity, absolute trickle timeout,
refusal/privacy, failed close/capture and preserved operator interruption.
Observation cases cover both-node proof, guard interference, unknown/late proof,
and boolean journal rejection. They do not execute the full SSH runner or prove
any model/native cancellation behavior. First16-case passing execution is
retained separately as checks-1 before the narrower capture-error correction.

```sh
cd /Users/developer/DarkbloomDev/cluster-research/installed-http-cancellation-draft-20260915
/usr/bin/python3 -B -m unittest -v test_cancel_client test_cancellation_observation
```

`source-lineage.json` pins original client/harness inputs. `harness.patch` shows
only runner/physical-IO changes; the observation helper is additive. Frozen
original client manifest and all of its members were verified in
`upstream-verification.json`. Review pending at this freeze is recorded honestly;
later reviews belong in separate supplements.
