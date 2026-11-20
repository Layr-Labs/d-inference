# Installed diagnostics HTTP smoke / fresh recovery request

Corrected V2 successor to the frozen diagnostics derivative of
`installed-product-lookahead-http-qualification-20260915`.
No old cohort/source is changed. No SSH, model, native or physical run was made.
The normal client, optional tokenizer preflight, alias/resource guards and actual
native-process/journal cleanup requirements remain unchanged.

Both `guards.py` and `supervisor.py` select the fresh installed root:
`/Users/developer/DarkbloomDev/installed-distributed-diagnostics-runtime-20260915`.
Root deploys the existing supervisor/monitor/resource helper files there. Include
**both** `qualification-tools/stage_checks/__init__.py` and `common.py`; this
package copies them exactly and now pins them explicitly in each run's inputs.
No recursive input scan enters future `physical-*` directories.

`run.py` adds two fixed read-only commands on the leader:

```
/Users/developer/DarkbloomDev/installed-distributed-diagnostics-runtime-20260915/darkbloom cluster status --json
```

The first follows listener/catalog/discovery readiness and precedes tokenizer
preflight and the external client. The second follows a successful normal client
completion and precedes supervisor shutdown. Neither is included in client TTFT.
The same Pair/session handles the one request; status performs no inference,
reload, physical probe, lease acquisition or recovery. A failed client does not
claim a normal-completion status capture.

`status_validation.py` follows the existing source-pinned diagnostics DTO:

- Require operation `status`, verified saved configuration and actual fresh live
  observation, with equal saved/live/session bindings. Merely exiting CLI0 does
  not suffice: the status CLI can report `live` absent without exiting nonzero.
- Require exact cluster `darkbloom-product-qwen9b-diagnostics-20260915`, leader
  role, public `Qwen3.5-9B`, native `registered_qwen35_9b`, configured auth and
  port18081; require serving/ready and no failed/quarantined state.
- Require a canonical observed membership epoch, the exact selected raw prefill
  value `one_chunk_lookahead_v1` and two bound `nativeReady` members with positive
  capacity. Both peer identities must be `darkbloom-24`/`darkbloom-48` in rank order.
- Require the fresh session's16 admissions before the request. Afterward require
  the same binding/epoch, a new nonce and15 admissions. The final snapshot may
  retain an active HTTP acquisition; its active/admission fields are retained.
  Status is an instant observation, not an ownership lease or cleanup proof.

`status_capture.py` uses a15-second absolute deadline for the fixed SSH/CLI
command, draining both streams concurrently with stdout capped64 KiB and stderr
capped16 KiB. Local child cleanup has a separate maximum2-second wait. Timeout,
overflow, nonzero exit, local cleanup error or invalid DTO fails the smoke and
enters the existing cleanup path. A local SSH exit/reap is explicitly **not**
remote native cleanup proof. No auth token is passed to this command, echoed in
exceptions or added to its receipt; bounded raw outputs are written mode0600.

Each phase retains `status-{before,after}.stdout.json`, `.stderr` and
`.receipt.json`. The execution record also retains validated binding, observed
epoch, nonce, nativeReady ranks and request/lifetime counters. Both validated
captures are mandatory for overall `completed=true`.

Run shape is unchanged, for example a4K normal smoke/recovery request after root
has independently established cleanup and configured/deployed both members:

```
/usr/bin/python3 -B run.py --attempt 1 \
  --prompt-file ../installed-http-long-prompts-20260915/fixtures/prompt-4096.txt \
  --declared-prompt-tokens 4096 \
  --client ../installed-http-client-draft-20260915/client.py
```

An existing attempt directory refuses overwrite. Recovery is a fresh invocation
under root coordination, not automatic journal clearing or process replacement.
Use the optional existing rendered-prompt/expected-token-IDs flags for a long
prompt preflight; their behavior is unchanged.

Validation:12 focused V2 tests PASS in0.338917667 s, including malformed/missing live
evidence, stale epoch/nonce, wrong counters, and five actual local Python children
for success/nonzero/partial-output timeout/stdout overflow/stderr overflow. All
14 Python source ASTs parse and pins remain unchanged. No remote/native test.
Three inverse edits restore original run/guard/supervisor files exactly;
eight copied files, including both stage helpers, remain byte-identical.
The saved binding is copied exactly from the actual stopped operator report
(SHA7e8de892ea29e9ceec050badc2aa125c264b5644742944f6f35a0d3042be4fd2).
It confirms300 seconds,16 requests and both actual peer IDs/native pins. That
report is explicitly rejected as live readiness; only the tests' live fields
are fabricated from the inspected DTO source. Tests also reject Swift enum case
names and the serial raw value. `ClusterPrefillSchedule.swift` is now pinned.
`lineage.json`, `status-source-pins.json`, `source-checks.json` and `checks-2/`
retain the exact source/test scope. Root review is pending at freeze.

`CORRECTION.md` records the initial validator bug. The inherited `checks-1/`
results and separate V1 manifest remain historical, not qualification of V2.
