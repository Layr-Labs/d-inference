# Zero-Downtime Model Migration Runbook

How to move a public model name from one build (quant) to another with **no downtime** and **without consumers ever seeing the quant** — using the model alias desired-build pointer and the provider's declarative self-reconcile.

> **AI agents: do not run any of these against prod.** Publishing to R2, registering on the prod coordinator, and flipping a prod alias are human-only actions. Validate on a throwaway/dev coordinator first. This runbook is the hand-off.

## How it works

A **public alias** (e.g. `gemma-4-26b`) resolves to a single **desired build** (the raw HuggingFace id the fleet should converge to), plus an optional **previous build** that stays acceptable while providers catch up. Consumers only ever send/receive the alias.

The coordinator pushes a `desired_models` message to each provider — right after it registers, and again whenever the desired build changes. A provider that is missing the desired build **prefetches** it in the background (download + verify on disk, no GPU load, no disruption to what it's serving), then **hard-swaps**: it advertises the new build and drops the old one via an authoritative `models_update`, and the coordinator retires the old build's routability on that provider.

Routing always prefers the desired build, accepts the previous build until the desired one is routable, and otherwise queues against the desired build — so traffic never black-holes. There are **no weights, no ramp, no pause/resume, and no migration controller**: a rollout is setting `desired_build`; a revert is setting it back.

Canonical code paths:

- Alias upsert + validation: [`coordinator/api/model_alias_handlers.go`](../../coordinator/api/model_alias_handlers.go):38–149
- Desired-models fan-out: [`coordinator/api/model_alias_handlers.go`](../../coordinator/api/model_alias_handlers.go):246–270
- Provider eligibility gate: [`coordinator/api/model_alias_handlers.go`](../../coordinator/api/model_alias_handlers.go):276–284
- Registry desired-models builder: [`coordinator/registry/registry.go`](../../coordinator/registry/registry.go):2270–2325
- Minimum provider version for desired-models: [`coordinator/api/server.go`](../../coordinator/api/server.go):148–154 (`minProviderVersionForDesiredModels = "0.5.17"`)

## Prerequisites

1. **Providers on a release that understands `desired_models`.** The coordinator gates on backend + version (`minProviderVersionForDesiredModels = "0.5.17"` in [`coordinator/api/server.go`](../../coordinator/api/server.go):154). Older providers are never sent `desired_models`; they simply keep serving whatever they already advertise.
2. **Coordinator must include the retired-resident-build challenge alibi.** The `active_model_hash` membership check accepts a catalog-validated hash from `model_hashes`. Without it, every hard-swapped provider reports its still-resident retired build as active at the next 5-minute challenge and is HARD-UNTRUSTED. Regression test: `TestChallengeRetiredResidentBuildHashDoesNotUntrust`.
3. **Canary the published build on one production-version provider first.** Prefetch, hash-verify, GPU-load, and serve chat + tool-call (+ vision if applicable) via the raw build id. Disk verification proves bytes, not loadability; the swap advertises BEFORE the first load, and a build that cannot load converts the fleet into repeated 500s with only a manual revert as the exit. (Load failures cool down routing per provider-model pair, which lets alias resolution fall back to `previous`, but do not rely on it as the primary safety.)
4. **For TAKEOVER migrations: pre-position the rollback build** before the flip (Step 6). `scripts/preposition-rollback-build.sh` server-side-copies the old weights to a distinct id and registers it.
5. **Watch keys during rollout:**
   - `/v1/models?include_builds=1` per-build routable counts (NOT `/v1/models/capacity`, which is keyed by concrete build ids and the public name's row decays to absent at full convergence).
   - Coordinator logs: `prefetch_model_status`, `models_update hard-swap: dropping retired build`, `load-failure cool-down started`, and the deroute signature `active model hash matches no advertised model`.

> **DAR-130 (tool-template crash) is fixed.** `ToolSchemaNormalization` injects default `type` fields into tool parameter schemas before the chat template renders them, so Gemma-style `{{ value['type'] | upper }}` templates no longer throw on typeless properties. See [`provider-swift/Sources/ProviderCore/Inference/ToolSchemaNormalization.swift`](../../provider-swift/Sources/ProviderCore/Inference/ToolSchemaNormalization.swift). Tool/agent traffic is no longer a blocker.

## Steps

### Step 1 — Publish the new build to R2

Produces a per-file + aggregate SHA-256 manifest and uploads to the model bucket. Reference: [`scripts/publish-model.sh`](../../scripts/publish-model.sh).

```bash
scripts/publish-model.sh
#   Model directory: <path to local mlx-community/gemma-4-26B-A4B-it-qat-4bit>
#   Model id:        mlx-community/gemma-4-26B-A4B-it-qat-4bit
#   Version:         v1
```

### Step 2 — Register the new build in the coordinator catalog

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
    "input_price": <micro_usd>,
    "output_price": <micro_usd>
  }'
```

The old build (`…-fp8`) should already be registered. Confirm both:

```bash
curl -s "$COORD/v1/models?include_builds=1" -H "Authorization: Bearer $KEY" | jq
```

### Step 3 — Create the public alias

> **Two shapes, depending on the public name:**
>
> **(a) Fresh alias** — the public name differs from every concrete model id. Create it pointing at the **current** (old) build first; no behavior change.
>
> **(b) TAKEOVER** — the public name IS the old concrete id (consumers already request it directly, e.g. `gemma-4-26b`). A same-name pre-step is **rejected** by validation (`desired_build` may never equal `alias_id`), so Steps 3 and 4 collapse into the **single atomic POST** shown in Step 4's takeover form. **Before that flip, pre-position the rollback build** (Step 6): a takeover alias cannot be flipped back to its own name.

Fresh-alias form (skip for takeover):

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

`GET /v1/models` now lists `gemma-4-26b` and hides the raw quant builds (consumers and the console UI pick this up automatically). Existing requests that still send the raw fp8 id keep working (passthrough).

### Step 4 — Roll out: flip `desired_build` to the new build

This is the whole migration. Set `desired_build` to the new build and keep the old build as `previous_build` so not-yet-swapped providers keep serving.

Fresh-alias form:

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

Takeover form (Steps 3+4 in one call — `takeover` acknowledges that the alias absorbs the existing concrete id; `previous_build` MUST equal the alias id; every subsequent upsert of this alias must keep `takeover: true`):

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "alias_id": "gemma-4-26b",
    "display_name": "Gemma 4 26B",
    "takeover": true,
    "previous_build": "gemma-4-26b",
    "desired_build":  "gemma-4-26b-qat-4bit"
  }'
```

On upsert the coordinator re-syncs the alias and pushes `desired_models` to every connected provider already serving the alias. Each provider prefetches the new build in the background, then hard-swaps. New/reconnecting providers learn the desired build via the `desired_models` push that follows their `register`. The download stagger across the fleet provides natural rate-limiting — there is no batch/step knob to tune.

### Step 5 — Monitor

```bash
# Live capacity per public name (routable/warm = desired + previous combined):
watch -n 10 'curl -s "$COORD/v1/models" -H "Authorization: Bearer $KEY" | jq ".data[] | select(.id==\"gemma-4-26b\")"'

# Raw per-build view (how many providers serve desired vs previous):
curl -s "$COORD/v1/models?include_builds=1" -H "Authorization: Bearer $KEY" | jq
```

Provider-side prefetch progress is logged as `provider prefetch_model_status` (started → downloading → verified) and the swap as `provider now advertises build (models_update)` / `models_update hard-swap: dropping retired build` on the coordinator.

**Failed downloads retry themselves.** A provider whose desired-build prefetch fails retries with bounded backoff (30s → 60s → 2m → 5m → 10m), resuming from the bytes already on disk. After the budget is exhausted it logs `giving up until the next desired_models push` and stays on its current build. **Manual unstick:** re-POST the alias upsert (Step 4 body, unchanged) — the fan-out resets every provider's retry budget and triggers an immediate re-prefetch.

## Verification

| Check | Expected outcome |
|---|---|
| `GET /v1/models` | Public alias is listed; raw quant builds are hidden behind it |
| `GET /v1/models?include_builds=1` | Desired build count rises; previous build count falls as providers swap |
| Provider logs | `prefetch_model_status` → `verified`; `models_update hard-swap: dropping retired build` |
| Consumer traffic | No 5xx surge; TTFB/latency stable; tool calls work on new build |
| Coordinator logs | No sustained `active model hash matches no advertised model` |

## Rollback

There is no separate rollback endpoint — a revert is the same operation as a rollout, pointed the other way. Set `desired_build` back to the old build:

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

Providers that still have the old build serve it immediately; the new build stays acceptable until they re-converge.

> **TAKEOVER aliases cannot use this revert** — `desired_build` back to the old id would equal `alias_id`, which validation rejects. The only fast revert is flipping to the old WEIGHTS under a **distinct id** that was pre-positioned BEFORE the migration:
>
> ```bash
> # Once, before the flip (server-side R2 copy + register + promote):
> # Registry fields are explicit — copy them from the absorbed build's registry row:
> #   …<new-id> <coord> <key> <quant> <min-ram> <max-ctx> <max-out> <in-price-µ$/Mtok> <out-price-µ$/Mtok> <caps-csv>
> scripts/preposition-rollback-build.sh gemma-4-26b <old-version> gemma-4-26b-8bit "$COORD" "$PUBLISHING_KEY" \
>   8bit 36 131072 16384 30000 165000 chat
>
> # Emergency revert is then a normal alias flip:
> curl -fsS -X POST "$COORD/v1/admin/models/aliases" … -d '{
>   "alias_id": "gemma-4-26b", "takeover": true,
>   "previous_build": "gemma-4-26b",
>   "desired_build": "gemma-4-26b-8bit"
> }'
> ```
>
> During the revert, providers that never swapped serve the absorbed id (`previous_build`) immediately — capacity never reaches zero. Already-swapped providers must fetch the rollback id (prefetch staging is keyed by the new build's R2 prefix, so plan for a re-download even though the bytes are hash-identical) and re-converge. Without pre-positioning, the only emergency exit is DELETE-ing the alias — which strands already-swapped providers on a build the public name no longer reaches. Do not plan a takeover migration without the rollback build registered first.

## Retire the old build

> **Prefer clearing `previous_build` only after EVERY provider has swapped to the desired build** (check `/v1/models` capacity for the alias, or confirm the previous build has zero routable providers). Until they converge, stragglers still advertising only the old build serve no alias traffic. They are NOT permanently stranded, though: every upsert records the rotated-out builds in the alias's `retired_builds` lineage, and the registration/fan-out membership gate matches desired, previous, *or* retired members — so a machine that was offline through the retirement is still told to converge when it returns or on the next alias upsert.

Once **all** providers serve the desired build, retire the previous build by re-POSTing the alias **without** `previous_build`:

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

With no acceptable previous build, the alias resolves only to the desired build (queuing against it if a straggler hasn't swapped yet). The old build unloads from GPU via the normal idle timeout. There is no auto-clear of `previous_build` in this release — retiring it is this explicit operator step.

Optional, once you're confident: deprecate the fp8 model registry entry.

> **TAKEOVER aliases retire in a different order.** The upsert above is **rejected** for a takeover alias: without `takeover` the absorbed-id collision check 409s, and with `takeover: true` validation forces `previous_build == alias_id`, so previous can never be cleared while the absorbed registry record is live. The sequence is:
>
> 1. Wait for full convergence **plus the residency drain** (the idle monitor unloads retired GPU slots up to an hour after each box's last old-build inference). Deprecating the absorbed record earlier removes its catalog hash, which voids the challenge alibi for any provider still holding the old build resident-and-active — it would be HARD-UNTRUSTED at its next challenge.
> 2. Deprecate the absorbed registry entry (`POST /v1/admin/models/gemma-4-26b/status` → deprecated). It drops out of the active/beta catalog, so the collision check no longer fires.
> 3. Re-upsert the alias **without** `takeover` and **without** `previous_build` (the form above). The absorbed id rotates into `retired_builds` lineage for straggler convergence.

## Validate on dev first

Run the whole flow against the dev coordinator (`api.dev.darkbloom.xyz`) with a couple of throwaway provider machines before touching prod. The coordinator-level invariants (prefer-desired routing, accept-previous fallback, no black-hole, the hard-swap drop of the retired build, and the post-register `desired_models` push) are covered by `coordinator/registry/alias_test.go` and `coordinator/api/model_alias_handlers_test.go`.
