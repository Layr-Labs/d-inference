# Measure coordinator startup after the old process stops

> Last updated: 2026-09-10 · commit `d93c2c335`

Use `scripts/measure-coordinator-startup.py` to observe the interval after the
old coordinator stops. The preceding drain is outside this measurement. The
tool performs no restart, hotswap, migration, configuration change, or APNs
mutation. Default mode only reads public health, readiness and capacity.

## When to use

Use this observer during an approved upgrade or a disposable rehearsal to measure
post-stop recovery. It records evidence; it does not authorize or execute a swap.

## Prerequisites

- Python 3.10 or newer; only the standard library is used.
- The candidate's exact `build_commit` value as emitted by `/health`, and an
  explicit list of exact model IDs from `/v1/models/capacity`.
- Authoritative UTC lifecycle timestamps. Use the old container's
  `State.FinishedAt` for stop and candidate's `State.StartedAt` for start when
  measuring container deployment. Do not substitute drain-start or the current
  wall clock. Container start includes the existing two-second MicroMDM wait;
  an actual coordinator-process start timestamp measures a narrower interval.
- One direct coordinator origin, or the public origin if measuring the customer
  network path. Public HTTP responses can come from a proxy; only a successful
  candidate-matching `/health` establishes that the candidate is reachable.

Migrations and new index creation must be prepared separately under the
[deployment procedure](coordinator-deploy.md#optional-prepare-compatible-migrations-before-draining).
First-install backfills/indexes can still delay startup; the observer does not
skip them or establish a five-second target in advance.

## Steps

### 1. Observe health, readiness and per-model capacity

Populate the timestamp/build variables from the deployment record, then run:

```bash
python3 scripts/measure-coordinator-startup.py \
  --base-url https://api.darkbloom.dev \
  --expected-build-commit "$CANDIDATE_COMMIT" \
  --process-started-at "$CANDIDATE_STARTED_AT" \
  --old-process-stopped-at "$OLD_PROCESS_STOPPED_AT" \
  --model EigenLabs/Qwen3.8-27B-4bit-mtp \
  --model qwen3.5-35b-a3b \
  --duration 180 --interval 0.5 \
  --output /tmp/coordinator-startup-observation.json
```

No API key is needed. Existing output files are refused. The JSON file is
created with mode `0600` and contains only bounded HTTP outcomes, build/model
identifiers, counts, timestamps, timing milestones and test-result booleans.
Response bodies, prompts, output text, usage/token data and credentials are not
written. Redirects and environment HTTP proxies are disabled.

The milestones are:

1. First HTTP response, including proxy errors such as 503.
2. First successful `/health` from the exact expected build.
3. First `/readyz` with `ready=true` and `draining=false`.
4. First eligible capacity for each requested model: `ready=true`,
   `can_accept=true`, and positive `routable_providers`.
5. First sample with all requested models eligible simultaneously.
6. Only with the explicit test probe below: first completed successful inference
   per model, plus a `first_inference` milestone for the first successful model.
   Read-only mode leaves inference and correctness unverified.

The report distinguishes first-observed milestones from internal process bind
times. Each includes elapsed milliseconds from candidate start and, if supplied,
old-process stop. `last_unsatisfied` records the previous negative observation;
`left_censored=true` means the condition was already satisfied on its first
observation. A late observer cannot reconstruct the exact transition. Polling,
network time, unverified cross-host clock alignment and the capacity endpoint's
existing two-second cache limit timing precision. Readiness and capacity are
samples, not continuous-availability guarantees or proof of successful inference.

### 2. Optionally probe inference in a disposable test environment

Only use an explicitly authorized test account and disposable environment.
Supply a JSON configuration such as:

```json
{"environment":"disposable-test","base_url":"http://127.0.0.1:8080","api_key_env":"DARKBLOOM_STARTUP_TEST_KEY"}
```

Set that environment variable through the test environment's secret handling,
then add both `--allow-test-inference` and `--test-inference-config PATH` to the
observer command with the matching test origin. Either flag alone is refused.
Known production origins are refused for this mode; declaring a different host
as disposable is the operator's responsibility, not automatic proof of safety.

The probe sends one fixed synthetic prompt long enough to clear the default
input floor and asks for exactly `STARTUP_OK`, with at most three attempts per
model and at most one request per second across all models. It only runs after
candidate readiness and that model's capacity gate. It requires HTTP 200, a
matching response model, non-empty content and a terminal `stop`/`length` reason.
It records completion time, not streaming TTFT. Later models' probe times
include the observer's one-request-per-second scheduling delay; the report records
probe start and elapsed time since first observed model capacity. Use
`first_inference` to compare time to the first actual completed test request,
not the last model's completion time as a pure startup delay. The content is examined in
memory and discarded: availability success and exact synthetic-answer correctness
are separate booleans. This small check does not qualify model quality, trust
correctness, billing, encryption, or sustained load behavior.

## Verification

- Exit `0`: the selected observation target was reached. In read-only mode this
  means readiness plus simultaneous per-model capacity; `inference_verified`
  remains false. In test mode, per-model inference and the exact synthetic reply
  also passed.
- Exit `1`: the observation window ended before the selected target was reached.
  Inspect missing milestones and bounded HTTP status counts.
- Exit `2`: invalid configuration or an unavailable output path.
- Exit `3`: inference availability was observed but a synthetic answer differed.
  The timing evidence remains in the report; correctness is marked failed.

No result authorizes a deployment. Keep the 45-second drain decision separate
from measured post-stop startup downtime and from any future traffic-handoff work.

## Rollback

Read-only observation changes no service state and needs no service rollback.
Stop the observer to end polling. In test mode, stopping it prevents future
probes; completed synthetic requests and their test-account usage are not undone.
Keep reports when they are needed as deployment evidence.

## Related

- [Coordinator deployment](coordinator-deploy.md) — approved preparation, swap and rollback.
- [Coordinator tests](../developer/test.md#coordinator-startup-and-reconnect-recovery) — local observer and startup regression tests.
- [Storage](../architecture/storage.md) — durable history recovery and migration progress.
