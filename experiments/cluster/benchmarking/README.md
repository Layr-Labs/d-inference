# Paired prefill studies

This module schedules and summarizes the primary 8K prefill comparison through
an explicitly supplied cohort adapter. It fixes ten distinct prompt pins, one
solo condition and one distributed condition, with one excluded warmup and
three measured requests per prompt/condition. It does not supply a native
execution adapter or qualify the [distributed-inference goal](../../../docs/design/distributed-inference-goal.md).

## Study specification

`specification.read_study` accepts the closed `cluster_prefill_study_v1` schema:

| Field | Meaning |
|---|---|
| `study_id`, `seed` | Bounded study label and deterministic ordering seed |
| `artifact_sha256`, `configuration_sha256` | Common model and configuration identity |
| `numerical_policy`, `tokenizer_sha256` | Common arithmetic policy label and tokenizer identity |
| `chunk_size` | Common prompt chunk size, from 1 through 8,192 |
| `prompts` | Exactly ten `{id, prompt_sha256, origin_sha256}` records; IDs and raw prompt hashes must each be unique |
| `conditions` | Exactly two `{id, role, runtime_identity_sha256, device_ids}` records, with roles `solo` and `distributed` |

The solo device must be one of the two distinct distributed device labels.
These are declared identities, not physical-device verification. Select the
fastest correct, eligible solo implementation through separate calibration
before freezing the comparison. This module does not establish that selection,
prompt representativeness, held-out status or the contents of referenced files.

`read_study` returns detached metadata with fixed `token_count=8192`,
`batch_size=1`, `warmup_count=1` and `measured_runs=3`. The input cannot override
those constants. `make_schedule` accepts raw or normalized metadata and returns
20 cohorts containing 80 unique request IDs. A cohort holds one prompt and one
condition for its warmup and three measured requests. Prompt ordering uses a
domain-separated hash of the seed and prompt ID. Solo goes first for five
prompts and distributed goes first for five; input array order cannot change it.

## Adapter interface and execution

With `experiments/cluster` on `PYTHONPATH`:

```python
from benchmarking.coordinator import run_study

result = run_study(raw_specification, open_cohort, on_event=save_event)
```

`open_cohort(study, cohort)` must return a context manager. Its value supplies
`run(request)`, returning exactly:

```python
{
    "elapsed_ns": elapsed_nanoseconds,
    "prompt_tokens": 8192,
    "generated_tokens": 1,
    "source_sha256": original_measurement_record_sha256,
}
```

The adapter verifies the pinned artifact, input bytes, runtime identity and
condition before execution. It owns resource/transport admission, deadlines and
cleanup, including failure during context entry. Weights remain loaded for the
four requests; every request gets fresh attention and recurrent state. The
measured interval starts with prepared engine input and ends at the first target
token after required GPU/communication completion. Loading, tokenization, API
overhead, cached tokens and speculative proposals are excluded from this metric
and need separate reporting. The coordinator checks the scalar record shape and
counts; it does not attest these timing boundaries or audit the referenced file.

Cohorts run sequentially. Any request, measurement, entry, close or event-sink
failure stops the study without retry or replacement. Every remaining planned
request becomes `skipped`. An adapter cannot hide a failed request by suppressing
its context-manager exception. Interrupts unwind the active context and are
re-raised with a `study_result` attribute containing partial results.

The optional event sink receives detached start/result records before subsequent
work begins. Use it for durable journaling outside the repository; the returned
in-memory result alone cannot survive process termination. Sink failure also
stops the study and sets `publication_failed`. Adapter errors and private device
labels can appear in the journal. No default output location is used.

## Aggregation

`aggregate.summarize(study, schedule, outcomes, cohort_errors)` revalidates the
exact schedule and each supplied outcome. For a complete study it calculates:

```text
median over ten prompts (
    median over three measured runs (8192 × 1e9 / elapsed_ns)
)
```

Warmups never enter the statistics. The result retains all measured samples,
per-prompt medians, paired prompt speedups and nearest-rank p95 latency with
sample counts. Rational arithmetic determines medians and the 800/1,000 TPS
comparisons before presentation as JSON numbers.

Missing, failed or skipped requests, failed warmups and cohort errors make the
study incomplete and withhold the condition aggregates and target comparisons.
Available individual samples and complete prompt pairs remain visible; any
partial latency tail describes only its reported sample count. Duplicate,
unplanned or structurally invalid supplied outcomes are rejected.

`supplied_result_target_met` and `supplied_result_stretch_met` compare complete
supplied values with the goal's thresholds. `performance_qualification` and
`runtime_admission` remain false. Physical hardware, fresh state, numerical
correctness, representative prompts and actual timing must be established by
the execution/qualification workflow.

## Current integration and checks

The tests use fabricated cohort adapters and timings. No model or native process
is launched. The existing [long-prefill commands](../runtime/stage_checks/LONG_PREFILL.md)
retain their current bounds. The internal resident rank owner and a matching
solo owner still need explicit adapters; increasing one-shot repeat flags does
not provide resident warmup. A real ten-prompt workload set is also outstanding.

From `experiments/cluster`, run:

```sh
python3 -B -m unittest -v benchmarking.test_specification \
  benchmarking.test_aggregate benchmarking.test_coordinator
```
