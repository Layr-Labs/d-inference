# Private resident worker pipe adapter

This is a stdlib Python 3.9+ transport foundation for one local solo process or two ordered local rank processes. It is not wired to a real numerical checker or the public benchmark coordinator. All executed tests use the invented `fake_worker.py`; no native model executable, SSH, GPU or compiler is invoked by those tests.

## API

```python
from worker_adapter import ResidentWorkerCohort
from worker_contract import WorkerSpec

cohort = ResidentWorkerCohort(
    workers=[WorkerSpec(tuple(approved_argv), dict(explicit_environment), "solo", None)],
    cohort_id="prompt:condition",
    requests=[  # exactly these four suffixes, with four unique lowerhex32 epochs
        {"request_id": "prompt:condition:warmup:0", "epoch": epochs[0]},
        {"request_id": "prompt:condition:measured:0", "epoch": epochs[1]},
        {"request_id": "prompt:condition:measured:1", "epoch": epochs[2]},
        {"request_id": "prompt:condition:measured:2", "epoch": epochs[3]},
    ],
    output_directory=fresh_output_directory,
    timeout_seconds=315,
    resource_gate=required_resource_gate,
    identity_validator=required_identity_validator,
    numerical_validator=required_numerical_validator,
)
with cohort:
    for request in the_exact_four_scheduled_requests:
        measurement = cohort.run(request)
transport_evidence = cohort.evidence()
```

Two-rank workers must be `[WorkerSpec(argv0, env0, "rank", 0), WorkerSpec(argv1, env1, "rank", 1)]`. The supplied environment replaces inherited environment; no shell is used. The caller owns argv/native/bundle/source admission before execution. Commands contain only the closed open/run/shutdown controls, never model flags.

`resource_gate(phase)` is required. It runs before launching and before every request, plus at pipe waits and command boundaries. It must return `None` on success and raise on refusal. The caller must implement actual resource, power, source and deadline policy appropriate to the approved worker. This module invents no resource thresholds or execution permit.

`identity_validator(worker_spec, event, expected_command)` is required for every ready/result/released/stopped event. It must return `None` on success and raise on failure. Inputs are detached; changing them cannot change retained commands or worker specifications. Event identity/order and the exact result command are checked here, but deeper Step UUID/history/prompt, source/configuration/Plan/layout, runtime/arithmetic, resource observations and release claims require this callback. The final result record envelope requires five object fields: command, step, execution, resourcesBeforeRequest, resourcesAfterRequest.

`numerical_validator(command, ordered_result_events)` is required for each request. It receives one solo event or rank0/rank1 events in that order, after each has passed identity validation. It must raise on any numerical failure and return an explicit JSON-finite CPU dictionary on success. The returned dictionary is detached. A real callback must produce the benchmark measurement schema with a correctly bound loading-excluded first-token interval; the public coordinator must still apply its own `validate_measurement`. No real callback is supplied here. Callback presence or successful return is not independent numerical qualification.

## Process and ordering behavior

Entry launches every worker in its own new process group, writes the exact open control to each and requires validated ready events. Each run accepts only the next exact `{request_id, phase, iteration}` from the four predeclared controls. Every command is fully written to every stdin before any corresponding event is validated. Already observed complete or partial unsolicited output at a command boundary is rejected. Results are validated as each worker produces them; a bad first worker does not wait for a stalled second worker. No next run command is sent before the numerical callback returns successfully.

The fourth run also requires each released event. Clean close then sends shutdown sequence5, requires stopped from both workers, final LF/EOF on output streams and native exit0. Extra events, early close, failed context entry, invalid input, callback errors, unexpected stderr and interrupts fail the cohort and trigger kill/reap attempts for all owned process groups. A pending request is never retried. Cleanup continues after an interruption and then preserves it; an original operator interruption stays primary over a secondary cleanup interruption. Cleanup errors remain in `evidence()` or on the original exception's `worker_cleanup_errors` where attachment is possible.

V2 guards each initial group kill and formats cleanup errors without trusting their `__str__`. The watchdog remains active until owned leaders are reaped. `closed` is set only after reaping and handle closure; unsuccessful teardown keeps new work refused and allows a later `close()` retry. If teardown remains unsuccessful, `evidence()` cannot claim a closed stream snapshot: retain the exception/cleanup diagnostics and the owner for further cleanup. OS failures do not become successful teardown evidence. Frozen V1 and its earlier test receipts are retained separately.

The worker lifetime is a single `1...315` second deadline starting immediately before process setup, never reset by requests. A daemon watchdog kills the owned groups on expiry even during a slow Python callback. The adapter cannot preempt arbitrary Python callback code or an OS call which itself blocks; callbacks must be bounded. Process creation and descendants must remain in the owned process groups. This is not a sandbox or proof about a worker that deliberately detaches itself.

## Retained bytes and limits

The output directory must be fresh; it is created mode0700. Exact bytes successfully written to stdin and read from stdout/stderr are retained in exclusive mode0600 `worker-N.stdin`, `.stdout`, `.stderr` files. Output lines are LF framed, at most32MiB excluding LF. The combined stdout/stderr cap across both workers is160MiB, stronger than the native per-worker160MiB cap. Stderr must be empty for this closed worker.

On a cap violation, only the bounded observed prefix is retained. Any failed path sets `output_complete=false`; bytes still unread at cancellation are not claimed retained. Only clean stopped/EOF/exit0 and successful cleanup set it true. Stream hashes in `evidence()` describe the retained files at that read; they do not attest execution, build lineage, actual loaded libraries or hardware. Raw files and evidence still need caller-owned immutable snapshot/publication if used in a later proof. Events supplied before commands can be detected when observed in the pipe, but this cannot prove when a worker performed computation.

`performance_qualification`, `runtime_admission`, independent numerical correctness and independent resource admission remain false. Cross-condition comparison, actual hardware placement and representative workload qualification are external.

## Fake tests

From this directory:

```sh
python3 -B -m unittest test_worker_adapter test_cleanup_v2 -v
```

The fixtures use explicit fake Python commands and bounded timeouts. They cover solo/two-rank success, private exact logs, failed enter/partial spawn, group expiry, callback/refusal/replay paths, partial output, reduced cap boundary cases, required release/stopped/EOF/exit0, short stdin writes, eager output before permission, reentrant failure poisoning and cleanup interrupts. Four added V2 methods exercise initial-kill interruptions, unprintable kill/wait failures, original operator-interruption priority and later teardown after an unretired fake group. Reduced caps exercise the same paths without allocating160MiB. Python3.9 AST parsing is included; that is not a Python3.9 execution claim.
