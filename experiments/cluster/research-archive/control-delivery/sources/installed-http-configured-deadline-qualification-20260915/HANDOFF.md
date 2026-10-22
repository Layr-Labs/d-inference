# Installed configured-deadline negative test

This runnable private derivative deliberately selects a two-second request deadline for one 8192-token request. It does not reproduce or claim a natural 18.192-second miss. The c408 Provider, ffcbd native worker, capability, lookahead schedule, model inputs, native resource policy and fixed owner lifetime are unchanged. The ordinary saved setup still uses 120 seconds. No real default switch, SSH operation, native inference or compiler was executed during preparation.

Root has authorized the temporary default-reference switch on both development Macs. Actual execution remains gated on root's source review and exclusion of conflicting physical/build work. The frozen cold8K observer and its physical-1 normal success remain untouched.

## Root invocation

Verify this frozen manifest's hash and members first, then run from this directory with a fresh attempt number:

```sh
/usr/bin/python3 -B run_configured.py --attempt 1 --execute
```

The outer driver sets the explicit parent `PYTHONPATH` when launching the inherited harness, avoiding the original direct-invocation import failure. Do not launch `harness/run.py` directly: the outer transaction prepares, installs and restores both provider pointers. An attempt directory is never overwritten.

The observer still uses the unchanged 90-second client observation limit and 100-second client parent bound. The existing remote supervisor/monitor/alias and cleanup bounds remain unchanged. The outer driver only waits; it does not issue a normal stop during the autonomous observation. On interruption it asks its own harness to enter its existing cleanup path before restoration. An additional outer wait bound does not prove native retirement.

## Exact configuration transaction

Both inputs change only `clusterID` and `requestTimeoutSeconds` from the current canonical configuration. They use the existing installed executable paths. The predicted configuration hashes are:

| Host | Temporary canonical configuration SHA-256 |
| --- | --- |
| darkbloom-24 | `7f2a82af486b2b58ed17a620b51e8ceceaf187e7a1f781f91d36bf1aa9a9c536` |
| darkbloom-48 | `8d895c8217ea0896e406069faa92770bbe6d651d7ea4de8c866274fde4df967c` |

The driver first prepares both hosts without changing either default. It requires no product/native process, an empty native journal and the exact current default Provider TOML SHA/mode. The fixed canonical path is `/Users/developer/.config/darkbloom/provider.toml`; a deployment using another default location is refused, not silently redirected. It verifies the installed Provider executable and capability, captures the original TOML privately and calls the real existing `cluster configure --config <transaction-copy>` to produce the exact proposed postimage. This validates the same strict configuration/trust/capability policy and publishes only inert content-addressed records. The original default must remain byte-identical throughout preparation.

Only after both preparations succeed does it swap defaults. Each swap acquires the existing canonical empty device lease and existing Provider sidecar lock, rechecks process absence, compares the original hash/mode, atomically replaces the default, fsyncs and reads it back. There is no TOML reimplementation, HOME override, new product protocol, arbitrary journal clearing or new device namespace.

Durable remote pre/postimages and their binding are stored at:

```text
<existing-runtime>/configuration-transactions/configured-deadline-1/
  provider.before.toml
  provider.after.toml
  configure.json
  configure.stdout
  configure.stderr
  state.json
```

They are private files. Raw Provider TOML never travels back in stdout. The local `transactions/attempt-1` directory records each bounded remote command, its output hash and the captured postimage pin before installation proceeds. Preparation refuses existing transaction directories.

Every ordinary, failure or interruption path attempts restoration on both hosts independently. Restore requires no product/native process, an empty native journal, the same existing locks, and a default equal to the captured postimage or the already-exact original. It restores and verifies exact original bytes and mode, preserving unrelated TOML data/comments. An unrelated concurrent edit, unsafe file, unresolved ownership or unreachable host cannot be called restored. The final `defaultsRestored` field and test exit status require both proofs.

If the local driver is killed or a host cannot be verified, retain all evidence and retry the recovery-only command after actual cleanup:

```sh
/usr/bin/python3 -B run_configured.py --attempt 1 --execute --restore-only
```

Recovery reads and hash-checks each retained successful preparation receipt independently. Missing/untrusted receipt data can only verify an already-exact original; it cannot authorize overwriting another value. Corruption on one host does not skip the other's restoration. This command starts no inference. No program can prove restoration while a host is unreachable: pending restoration remains explicit and must be resolved before another test. Temporary content-addressed cluster records and transaction backups remain inert after the original references are restored.

## What qualifies

The reused client must observe HTTP200, no visible content, a closed typed `deadline_unreachable` error or `inference_error` with `safety_deadline`, reported `attempt_usage` 8192/0, exactly one terminal, DONE and actual body EOF. It remains client exit1, failed inference and failed SLA. The unchanged external content metric remains 18.192 seconds. The configured two-second cutoff is recorded separately; this derivative requires error arrival after that configured cutoff, not after 18.192 seconds.

The HTTP and engine deadline timers can race. Their two allowed error variants describe that race; unrelated prefill/resource/runtime errors do not qualify. A normal successful response remains successful inference in its own fields and fails this expected-error qualification. Missing or duplicate terminals, false usage, incomplete EOF/DONE, changed SLA or late visible text also fail it.

Qualification additionally requires a fresh actual authenticated ready status bound to the temporary canonical leader configuration; no parent/resource-guard intervention during autonomous cleanup; native/CLI absence and empty journals on both hosts; natural runtime-failure Provider exit1 without forced kill; restored alias; clean resource monitors; unchanged source pins; and exact restoration of both default references. Response EOF, elapsed time and process exit alone are not native/owner ACK proof. The inherited owner/harness retains those obligations. Root should inspect the retained lifecycle records for reserved → terminal → retired before describing active-work deadline cancellation; reported usage is not an independent token audit.

## Reuse and validation

The terminal client and its parser, the five installed remote helper files, resource sampler, alias lease and autonomous-cleanup observer are byte-exact inherited members. The supervisor, helpers and current binaries need no redeployment. Only the expected status/configuration binding, result directory prefix and terminal qualification change. The four new transaction runtime files are separate from that inherited control path. `source-lineage.json` and `runtime.patch` record exact changes; the frozen predecessor manifest is retained for comparison.

`checks-1` preserves the initial 11 passing model-free checks. `checks-2` passed 25 checks in 0.274 seconds under `/usr/bin/python3`, with all source hashes unchanged: fifteen new file/transaction/DTO/recovery cases, four inherited terminal-contract cases and six unchanged cleanup-observer cases. The tests use actual private temporary files and two CPU Python children, including bundled remote-code rejection before any file access. Configure and process observation are mocked in the file fixture; the actual installed CLI transaction and both-host physical sequence remain unexecuted. No sockets, SSH, model, compiler or installed configuration was touched by these checks.

Run the same exact command listed in `checks-2/execution.json` for the focused model-free regression set. Original full client/SSE fixtures are retained unchanged; they were qualified in the predecessor and were not rerun here. Root owns final source review, actual staged configure results, physical evidence and restoration verification.
