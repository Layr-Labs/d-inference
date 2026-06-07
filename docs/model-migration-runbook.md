# Zero-Downtime Model Migration Runbook

How to move a public model name from one build (quant) to another with **no
downtime** and **without consumers ever seeing the quant** — using the model
alias + background prefetch + migration controller built in this feature.

First user: migrate **`gemma-4-26b`** from `…-fp8` (~27 GB) to
`…-qat-4bit` (~15.6 GB). The new QAT build is higher quality at lower memory,
and at `min_ram_gb≈22` it also opens the entire 32 GB Mac tier (fp8 was gated to
64 GB+).

> **AI agents: do not run any of these against prod.** Publishing to R2,
> registering on the prod coordinator, and starting a prod migration are
> human-only actions. Validate on a throwaway/dev coordinator first. This
> runbook is the hand-off.

---

## How it works (one paragraph)

A **public alias** (`gemma-4-26b`) resolves to one or more concrete **builds**
(the raw HuggingFace ids) each with a routing **weight**. Consumers only ever
send/receive the alias. The **migration controller** tells old-build providers
to **prefetch** the new build in the background (download + verify on disk, no
GPU load, no disruption to what they're serving); as providers finish and
re-advertise the new build, the controller **ramps** the alias weight toward it
(canary → 100%, clamped per tick, health-gated) and **drains** the old build to
weight 0. Resolution always prefers a build that has a live provider, so traffic
never black-holes mid-ramp. Draining to 0 stops new traffic; the old build
unloads from GPU via the normal idle timeout.

---

## Prerequisites

1. **DAR-130 (chat_template) must be fixed first.** The qat-4bit build ships the
   same unguarded `{{ value['type'] | upper }}` template as the 8-bit build,
   which crashes swift-jinja on tool definitions that omit a `type`. Until the
   provider-side normalization (or a re-vended template) lands, tool/agent
   traffic on the new build will 500. The alias migration is **blocked-by
   DAR-130** for exactly this reason.
2. Providers on a build version that supports the prefetch protocol
   (`prefetch_model` / `prefetch_model_status`) and the background downloader
   (this feature's provider release).

---

## Step 1 — Publish the new build to R2 (human)

```bash
# Produces a per-file + aggregate SHA-256 manifest and uploads to the
# darkbloom-models bucket. See scripts/publish-model.sh.
scripts/publish-model.sh
#   Model directory: <path to local mlx-community/gemma-4-26B-A4B-it-qat-4bit>
#   Model id:        mlx-community/gemma-4-26B-A4B-it-qat-4bit
#   Version:         v1
```

## Step 2 — Register the new build in the coordinator catalog (human)

```bash
curl -fsS -X POST "$COORD/v1/admin/models/register" \
  -H "Authorization: Bearer $PUBLISHING_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "model_id": "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
    "version": "v1",
    "display_name": "Gemma 4 26B (QAT 4-bit)",
    "family": "gemma-4",
    "quantization": "4bit",
    "max_context_length": 131072,
    "max_output_length": 8192,
    "min_ram_gb": 22,
    "capabilities": ["chat","tools","reasoning","vision"],
    "promote": true,
    "input_price": <micro_usd>, "output_price": <micro_usd>
  }'
```

The old build (`…-fp8`) should already be registered. Confirm both:
`curl -s "$COORD/v1/models?include_builds=1" -H "Authorization: Bearer $KEY"`.

## Step 3 — Create the public alias (human)

Start with all traffic on the old build (`to` drained at 0 — the controller
ramps it):

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "alias_id": "gemma-4-26b",
    "display_name": "Gemma 4 26B",
    "builds": [
      {"build_id": "mlx-community/gemma-4-26b-a4b-it-fp8",      "weight": 100},
      {"build_id": "mlx-community/gemma-4-26B-A4B-it-qat-4bit", "weight": 0}
    ]
  }'
```

`GET /v1/models` now lists **`gemma-4-26b`** and hides the raw quant builds
(consumers, the console UI, and the landing page pick this up automatically).
Existing requests that still send the raw fp8 id keep working (passthrough).

## Step 4 — Start the migration (human)

```bash
curl -fsS -X POST "$COORD/v1/admin/migrations" \
  -H "Authorization: Bearer $PUBLISHING_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "alias_id": "gemma-4-26b",
    "from_build": "mlx-community/gemma-4-26b-a4b-it-fp8",
    "to_build":   "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
    "batch_size": 2,
    "max_step_percent": 20
  }'
```

- `batch_size` — how many providers are told to prefetch per ~20s tick (keeps
  download bandwidth/capacity impact bounded).
- `max_step_percent` — max points the new build's weight rises per tick (smooth
  ramp). The controller only ramps as fast as providers actually finish
  prefetching, so the real pace is capacity-bound.

## Step 5 — Monitor

```bash
watch -n 10 'curl -s "$COORD/v1/admin/migrations" -H "Authorization: Bearer $KEY" | jq'
# Shows per-migration: status, to_weight (0→100), providers_from, providers_to.
```

Provider-side prefetch progress is logged as `provider prefetch_model_status`
(started → downloading → verified) on the coordinator.

## Step 6 — Pause / resume / rollback (human)

```bash
curl -X POST "$COORD/v1/admin/migrations/gemma-4-26b/pause"   -H "Authorization: Bearer $KEY"
curl -X POST "$COORD/v1/admin/migrations/gemma-4-26b/resume"  -H "Authorization: Bearer $KEY"
# Rollback instantly reverts the alias to 100% old build and stops the migration:
curl -X POST "$COORD/v1/admin/migrations/gemma-4-26b/rollback" -H "Authorization: Bearer $KEY"
```

## Step 7 — Completion & cleanup

When `to_weight` reaches 100 and every old-build provider also serves the new
build, the controller marks the migration `complete`. The fp8 build is drained
(weight 0) — no new traffic — and unloads from GPU via the idle timeout.

Optional, once you're confident: remove fp8 from the alias and/or deprecate the
fp8 model registry entry.

```bash
# Drop fp8 from the alias (qat-only going forward):
curl -X POST "$COORD/v1/admin/models/aliases" -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"alias_id":"gemma-4-26b","display_name":"Gemma 4 26B",
       "builds":[{"build_id":"mlx-community/gemma-4-26B-A4B-it-qat-4bit","weight":100}]}'
```

---

## Validate on dev first

Run the whole flow against the **dev** coordinator (`api.dev.darkbloom.xyz`)
with a couple of throwaway provider machines before touching prod. The
coordinator-level invariant (no black-hole during ramp, public name stable, full
drain at the end) is covered by `TestZeroDowntimeAliasMigration` in
`coordinator/api/migration_e2e_test.go`.
