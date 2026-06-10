# Zero-Downtime Model Migration Runbook

How to move a public model name from one build (quant) to another with **no
downtime** and **without consumers ever seeing the quant** — using the model
alias **desired-build pointer** and the provider's declarative self-reconcile.

First user: migrate **`gemma-4-26b`** from `…-fp8` (~27 GB) to
`…-qat-4bit` (~15.6 GB). The new QAT build is higher quality at lower memory,
and at `min_ram_gb≈22` it also opens the entire 32 GB Mac tier (fp8 was gated to
64 GB+).

> **AI agents: do not run any of these against prod.** Publishing to R2,
> registering on the prod coordinator, and flipping a prod alias are human-only
> actions. Validate on a throwaway/dev coordinator first. This runbook is the
> hand-off.

---

## How it works (one paragraph)

A **public alias** (`gemma-4-26b`) resolves to a single **desired build** (the
raw HuggingFace id the fleet should converge to), plus an optional
**previous build** that stays acceptable while providers catch up. Consumers only
ever send/receive the alias. The coordinator pushes a **`desired_models`** message
to each provider — right after it registers, and again whenever the desired build
changes. A provider that's missing the desired build **prefetches** it in the
background (download + verify on disk, no GPU load, no disruption to what it's
serving), then **hard-swaps**: it advertises the new build and drops the old one
via an authoritative `models_update`, and the coordinator retires the old build's
routability on that provider. Routing always prefers the desired build, accepts
the previous build until the desired one is routable, and otherwise queues against
the desired build — so traffic never black-holes. There are **no weights, no ramp,
no pause/resume, and no migration controller**: a rollout is setting
`desired_build`; a revert is setting it back.

---

## Prerequisites

1. **DAR-130 (chat_template) must be fixed first.** The qat-4bit build ships the
   same unguarded `{{ value['type'] | upper }}` template as the 8-bit build,
   which crashes swift-jinja on tool definitions that omit a `type`. Until the
   provider-side normalization (or a re-vended template) lands, tool/agent
   traffic on the new build will 500. The live cutover is **blocked-by DAR-130**
   for exactly this reason.
2. Providers on a release that understands `desired_models` and the background
   downloader (this feature's provider release, version ≥
   `minProviderVersionForDesiredModels` — see `coordinator/api/server.go`). Older
   providers are never sent `desired_models` (the coordinator gates on backend +
   version); they simply keep serving whatever they already advertise.

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

## Step 3 — Create the public alias, pointing at the OLD build (human)

Create the alias with `desired_build` = the **current** (old) build. This makes
`gemma-4-26b` a stable public name with no behavior change yet:

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "alias_id": "gemma-4-26b",
    "display_name": "Gemma 4 26B",
    "desired_build": "mlx-community/gemma-4-26b-a4b-it-fp8"
  }'
```

`GET /v1/models` now lists **`gemma-4-26b`** and hides the raw quant builds
(consumers, the console UI, and the landing page pick this up automatically).
Existing requests that still send the raw fp8 id keep working (passthrough).

## Step 4 — Roll out: flip `desired_build` to the new build (human)

This is the whole migration. Set `desired_build` to the new build and keep the
old build as `previous_build` so not-yet-swapped providers keep serving:

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "alias_id": "gemma-4-26b",
    "display_name": "Gemma 4 26B",
    "desired_build":  "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
    "previous_build": "mlx-community/gemma-4-26b-a4b-it-fp8"
  }'
```

On upsert the coordinator re-syncs the alias and pushes `desired_models` to every
connected provider already serving the alias. Each provider prefetches the new
build in the background, then hard-swaps. New/reconnecting providers learn the
desired build via the `desired_models` push that follows their `register`. The
download stagger across the fleet provides natural rate-limiting — there is no
batch/step knob to tune.

## Step 5 — Monitor

```bash
# Live capacity per public name (routable/warm = desired + previous combined):
watch -n 10 'curl -s "$COORD/v1/models" -H "Authorization: Bearer $KEY" | jq ".data[] | select(.id==\"gemma-4-26b\")"'

# Raw per-build view (how many providers serve desired vs previous):
curl -s "$COORD/v1/models?include_builds=1" -H "Authorization: Bearer $KEY" | jq
```

Provider-side prefetch progress is logged as `provider prefetch_model_status`
(started → downloading → verified) and the swap as
`provider now advertises build (models_update)` /
`models_update hard-swap: dropping retired build` on the coordinator.

**Failed downloads retry themselves.** A provider whose desired-build prefetch
fails (network blip, CDN hiccup) retries with bounded backoff (30s → 60s → 2m →
5m → 10m), resuming from the bytes already on disk. After the budget is
exhausted it logs `giving up until the next desired_models push` and stays on
its current build. **Manual unstick:** re-POST the alias upsert (Step 4 body,
unchanged) — the fan-out resets every provider's retry budget and triggers an
immediate re-prefetch.

## Step 6 — Revert (human)

There is no separate rollback endpoint — a revert is the same operation as a
rollout, pointed the other way. Set `desired_build` back to the old build:

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "alias_id": "gemma-4-26b",
    "display_name": "Gemma 4 26B",
    "desired_build":  "mlx-community/gemma-4-26b-a4b-it-fp8",
    "previous_build": "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
  }'
```

Providers that still have the old build serve it immediately; the new build stays
acceptable until they re-converge.

## Step 7 — Retire the old build (human, manual)

> **Prefer clearing `previous_build` only after EVERY provider has swapped to
> the desired build** (check `/v1/models` capacity for the alias, or that the
> previous build has zero routable providers). Until they converge, stragglers
> still advertising only the old build serve no alias traffic. They are NOT
> permanently stranded, though: every upsert records the rotated-out builds in
> the alias's `retired_builds` lineage, and the registration/fan-out membership
> gate matches desired, previous, *or* retired members — so a machine that was
> offline through the retirement is still told to converge when it returns or
> on the next alias upsert.

Once **all** providers serve the desired build, retire the previous build by
re-PUTting the alias **without** `previous_build`:

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "alias_id": "gemma-4-26b",
    "display_name": "Gemma 4 26B",
    "desired_build": "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
  }'
```

With no acceptable previous build, the alias resolves only to the desired build
(queuing against it if a straggler hasn't swapped yet). The old build unloads
from GPU via the normal idle timeout. There is no auto-clear of `previous_build`
in this release — retiring it is this explicit operator step.

Optional, once you're confident: deprecate the fp8 model registry entry.

---

## Validate on dev first

Run the whole flow against the **dev** coordinator (`api.dev.darkbloom.xyz`)
with a couple of throwaway provider machines before touching prod. The
coordinator-level invariants (prefer-desired routing, accept-previous fallback,
no black-hole, the hard-swap drop of the retired build, and the post-register
`desired_models` push) are covered by `coordinator/registry/alias_test.go` and
`coordinator/api/model_alias_handlers_test.go`.
