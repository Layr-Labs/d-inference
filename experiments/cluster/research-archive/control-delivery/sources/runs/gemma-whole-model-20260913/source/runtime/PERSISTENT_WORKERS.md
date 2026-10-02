# Persistent experimental rank workers

`PersistentCohort` keeps one native model load per rank across serialized text
requests. It is a runtime prototype, not a production provider engine or a
qualified performance result. The existing one-shot benchmark remains the
measurement path. A new request always creates fresh attention, convolution
and recurrent state; weights remain resident until the epoch ends.

## Python entry point

From an environment with `experiments/cluster` on `PYTHONPATH`:

```python
from pathlib import Path
from runtime.persistent import PersistentCohort

spec = {
    "schema_version": 1,
    "backend": "loopback-test",
    "partition": "full",
    "ranks": [{"location": "local"}, {"location": "local"}],
    "workload": {"synthetic": True, "synthetic_profile": "tiny"},
    "timeout_seconds": 60,
}
with PersistentCohort(spec, Path("/path/to/native/bundle"),
                      Path("/new/output/outside/repository")) as cohort:
    records = cohort.infer(
        "example-1", [3, 7, 11], 4, 2, timeout_seconds=30,
        on_token=lambda step, token: print(step, token),
    )
```

The bundle directory contains the built executable, `mlx.metallib` and its
SwiftPM resource bundle. The client snapshots these together with its rank
supervisor and verifies the snapshot before launching. Real model specifications
also require the expected source artifact hash and full manifest verification.
The same existing SSH staging supports the JACCL backend, but persistent remote
operation requires separate physical-machine validation. Independent replicas
need independent cohorts; this client rejects the `replicas` backend.

Request settings come from `infer`, not the workload's fixed benchmark prompt,
chunk size, repeat count or token files. `on_token(step, token)` is called once
only after the selected token and step match across all ranks. Teacher tokens
are an optional numerical diagnostic and must contain exactly the output count
minus one IDs. Generation is greedy with a fixed output count, including after
EOS. Sampling, continuous batching, multimodal inputs, MTP, prefix caching and
phase/state handoff are not implemented by this entry point.

## Native protocol

`--mode worker` or `--mode worker-tp` requires `--epoch` with 32 lowercase hex
characters. The native process reads version-1 JSONL commands on stdin and emits
version-1 JSONL events on stdout; diagnostics go to stderr. Each command has a
closed field set. Duplicate keys, escaped duplicate keys, fractional/exponent
integer encodings, invalid IDs, oversized frames and truncated EOF are rejected.

An inference command contains `version`, `type: "infer"`, `epoch`, `sequence`,
`requestID`, `prompt`, `outputTokens`, `chunkSize`, `timeoutSeconds` and
`captureLogits`, with optional `teacherTokens`. A shutdown command contains only
`version`, `type: "shutdown"`, `epoch` and `sequence`. Sequence numbers start at
one and must be consecutive; request IDs cannot repeat within an epoch.

| Limit | Protocol value |
|---|---|
| Input line | 2 MiB excluding newline; reader uses 4 KiB system reads |
| Request ID | 1–128 ASCII letters, digits or `_.:-` |
| Context | Prompt length plus output count ≤ min(declared model context, 32,768) |
| Outputs per request | 1–4,096 |
| Chunk size | 1–32,768 |
| Request timeout | 1–300 seconds |
| Requests per epoch | 4,096; shutdown may follow the final request |
| Captured logits | At most 1,048,576 finite values |

The initial `ready` event binds model/configuration, parameter layout, partition
plan, numerical policy, selected transport, source verification receipt when
available and request limits. It includes the native PID and a model-load ID.
The controller separately owns executable/bundle and source-artifact verification;
an absent native direct-load receipt is `none`, not a claimed verification.
Both ranks agree on epoch, identity and limits before readiness.

For each inference, both ranks agree on the complete canonical command before
emitting `accepted`. They then emit ordered `token` events and a `completed`
event containing `RunResult` and optional logits. Accepted/completed events bind
the command hash and original model-load ID. Canonical hashes use compact UTF-8
JSON with sorted keys and unescaped slashes/Unicode. The result's `iteration`
equals the command sequence. Output frames have a separate, larger bound because
captured logits can exceed the input line limit: 32 MiB per frame and 64 MiB of
queued serialized frame bytes. Parsed Python objects use additional memory.

## Failure and lifecycle

The controller admits one request at a time. A rank disagreement, protocol
failure, deadline, callback exception or cancellation retires the whole epoch.
It cancels every supervisor and their native process groups. The retired cohort
cannot be reused or silently retry a partial request. Future work requires a new
cohort and new epoch. Already emitted tokens cannot be revoked; caller accounting
must treat an interrupted request as failed with its actual emitted prefix.
An already admitted Python callback cannot be forcibly interrupted and may
finish after cancellation. The watchdog retires native work and prevents later
callback admissions; it cannot undo user callback side effects. Callers must
keep callbacks short and handle their own cancellation-sensitive output.

Idle close sends an agreed shutdown and waits for completion. Close during work
cancels it. Each native worker has independent startup, idle and per-request
alarms; the persistent supervisor continues checking cancellation and signals
without imposing one total lifetime deadline on successive requests. A broken
remote link can defer cleanup until the native deadline. This is not a claim of
instantaneous remote termination or authenticated product cluster membership.

Streaming callbacks and stdout backpressure can affect peer timing. Captured
logits also add work between model steps. Worker timing fields are diagnostic;
they cannot qualify the M3 Ultra prefill goal. The controller is an experimental
Python client, not the production CBv2 engine or its memory/admission ledger.

## Checks

```sh
experiments/cluster/inference/.build/arm64-apple-macosx/release/cluster-inference \
  --mode worker-protocol-check
python3 -m unittest discover -s experiments/cluster -p 'test_persistent*.py' -v
```

The native protocol check exercises parsing, canonical hashes, sequence state
and bounded framing without model/GPU work. Python tests use real CPU fixture
processes for supervisor, stream and cancellation failures. Synthetic native
model checks are separate evidence; physical JACCL, real-model qualification and
production integration remain required by the
[active goal](../../../docs/design/distributed-inference-goal.md).

The [dated native validation](../inference/PERSISTENT_VALIDATION.md) records
synthetic request isolation, one-shot equivalence and actual worker failure
checks with executable and source identities.
