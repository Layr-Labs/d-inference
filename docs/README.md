# Darkbloom documentation

> Last updated: 2026-09-03 · commit `5d400cf75`

> Darkbloom is a decentralized private-inference network: an OpenAI- and
> Anthropic-compatible HTTP API served by a Go coordinator that routes each
> request, re-encrypted per request, to an attested Apple Silicon Mac running
> the Swift `darkbloom` provider, which runs the model in-process with MLX.
> These pages describe the system as the code at the stamped commit implements
> it; the code wins every disagreement. Each page has one job (how-to, runbook,
> reference, explanation, design record, or dated report) and carries a
> freshness stamp. Rules for reading and writing them:
> [`AGENTS.md`](AGENTS.md). One name for each thing: [`glossary.md`](glossary.md).

## Start here, by task

- [`consumer/quickstart.md`](consumer/quickstart.md): make your first chat completion with an API key, curl, or an OpenAI/Anthropic SDK by changing the base URL.
- [`provider/installation.md`](provider/installation.md) then [`provider/quickstart.md`](provider/quickstart.md): turn a Mac into a paid provider node.
- [`developer/build.md`](developer/build.md) then [`developer/test.md`](developer/test.md): build and test every component locally.
- [`operations/README.md`](operations/README.md): deploy or change production (human approval required for every mutation).
- [`architecture/overview.md`](architecture/overview.md): understand the whole system in one page.
- [`architecture/security/encryption.md`](architecture/security/encryption.md): the exact, hop-by-hop privacy model — the only page that states it.

## How the system works (explanation)

- [`architecture/README.md`](architecture/README.md): index of every explanation page.
- [`architecture/overview.md`](architecture/overview.md): components, trust boundaries, and the request path end to end.
- [`architecture/data-flow.md`](architecture/data-flow.md): one request from consumer HTTP through routing, encryption, the provider WebSocket, and back as SSE.
- [`architecture/components/coordinator.md`](architecture/components/coordinator.md): the Go control plane — process layout, HTTP/WebSocket servers, store, background jobs.
- [`architecture/components/provider.md`](architecture/components/provider.md): the Swift provider — connection loop, engine bridge, hardened runtime, auto-update.
- [`architecture/components/consumer.md`](architecture/components/consumer.md): the consumer surface — OpenAI/Anthropic compatibility, SDKs, console.
- [`architecture/components/console-ui.md`](architecture/components/console-ui.md): the Next.js console — pages, `/api/*` relay handlers, Privy auth, SSE chat.
- [`architecture/components/admin-ui.md`](architecture/components/admin-ui.md): the internal read-only operator dashboard.
- [`architecture/components/mlx-swift.md`](architecture/components/mlx-swift.md): how the provider uses the pinned `mlx-swift` / `mlx-swift-lm` forks.
- [`architecture/routing.md`](architecture/routing.md): how a request becomes a provider choice — eligibility gates, cost model, selection, hedged dispatch, breakers.
- [`architecture/scheduling.md`](architecture/scheduling.md): per-model queues, slot states, token-budget admission, model swaps, warm pool, heartbeat and eviction.
- [`architecture/cache-aware-routing.md`](architecture/cache-aware-routing.md): provider-confirmed exact prefix-cache routing and its kill switch.
- [`architecture/inference.md`](architecture/inference.md): the engine — continuous batching, KV cache, memory model, MTP, vision, deadlines.
- [`architecture/prefix-cache.md`](architecture/prefix-cache.md): RAM and encrypted-SSD prefix caches — lookup rules, adoption, exactness.
- [`architecture/prompt-contract-sidecar.md`](architecture/prompt-contract-sidecar.md): the Rust sidecar that derives token boundaries for cache routing, and its failure isolation.
- [`architecture/model-registry.md`](architecture/model-registry.md): model manifests, aliases, publishing, and provider downloads.
- [`architecture/storage.md`](architecture/storage.md): coordinator persistence — Postgres schema, memory store, retention.
- [`architecture/billing.md`](architecture/billing.md): pricing, reservations, ledger, Stripe deposits and payouts, referrals, base rewards.
- [`architecture/telemetry.md`](architecture/telemetry.md): what telemetry exists, how the Go/Swift/TS mirrors stay symmetric, where it goes.
- [`architecture/request-outcome-observability.md`](architecture/request-outcome-observability.md): the closed outcome taxonomy for client, provider, and billing dimensions.
- [`architecture/system-profiler.md`](architecture/system-profiler.md): per-attempt request profiles and fleet snapshots — schema, clocks, validation.
- [`architecture/hardware-support.md`](architecture/hardware-support.md): Apple Silicon tiers and what each unlocks.

## Security and privacy

- [`architecture/security/encryption.md`](architecture/security/encryption.md): NaCl Box on each hop, what the coordinator decrypts and does not retain, key lifetimes.
- [`architecture/security/attestation.md`](architecture/security/attestation.md): trust levels and the exact conditions for each — Secure Enclave, MDM, MDA, APNs code identity.
- [`architecture/security/enrollment.md`](architecture/security/enrollment.md): MDM enrollment, profile generation and signing, webhook flow.
- [`architecture/security/identity-binding.md`](architecture/security/identity-binding.md): how APNs, X25519, SE P-256, and MDA identities bind to one provider.
- [`consumer/privacy-expectations.md`](consumer/privacy-expectations.md): what a consumer can and cannot assume, in plain terms.
- [`consumer/verification.md`](consumer/verification.md): how to check a provider's attestation from the API.
- [`provider/attestation.md`](provider/attestation.md): what runs on the provider to earn and keep trust, and what the operator can see.
- [`threat-model.yaml`](threat-model.yaml): machine-readable threat model reviewed by CI on security-relevant PRs.

## Reference (look up, do not read)

- [`reference/README.md`](reference/README.md): index.
- [`reference/api-contracts.md`](reference/api-contracts.md): every HTTP route, header, status code, and JSON shape of the coordinator.
- [`reference/protocol-messages.md`](reference/protocol-messages.md): every WebSocket message between coordinator and provider, field by field, Go ↔ Swift.
- [`reference/configuration.md`](reference/configuration.md): every environment variable of the coordinator, provider, console, and admin UI, with defaults.
- [`reference/telemetry-schema.md`](reference/telemetry-schema.md): telemetry event types, field allowlist, symmetry rules.
- [`reference/telemetry-inventory.md`](reference/telemetry-inventory.md): every telemetry datum collected, its producer, sink, and cadence.
- [`reference/pricing-model.md`](reference/pricing-model.md): micro-USD units, price resolution, fees, service accounts.
- [`reference/model-registry-format.md`](reference/model-registry-format.md): manifest schema, registration payload, alias format.
- [`reference/ssd-kv-cache.md`](reference/ssd-kv-cache.md): on-disk format and configuration of the encrypted SSD prefix cache.
- [`reference/ssd-kv-cache-hybrid-models.md`](reference/ssd-kv-cache-hybrid-models.md): adoption and recompute rules on hybrid sliding-window models.
- [`glossary.md`](glossary.md): canonical terms and the page that owns each.

## Consumer how-tos

- [`consumer/quickstart.md`](consumer/quickstart.md): first request, streaming, SDK base-URL swap.
- [`consumer/authentication.md`](consumer/authentication.md): API keys, Privy sign-in, service accounts.
- [`consumer/models.md`](consumer/models.md): the model catalog, aliases, capabilities, and how to query it.
- [`consumer/billing.md`](consumer/billing.md): funding a balance, reading usage, what a 402 means.
- [`consumer/verification.md`](consumer/verification.md): verify the provider that served you.
- [`consumer/privacy-expectations.md`](consumer/privacy-expectations.md): privacy in practice.
- [`provider/self-route.md`](provider/self-route.md): route your own requests to your own Mac for free.

## Provider how-tos

- [`provider/installation.md`](provider/installation.md): install, update, uninstall; what the installer verifies.
- [`provider/quickstart.md`](provider/quickstart.md): login, start, check status, start earning.
- [`provider/hardware-requirements.md`](provider/hardware-requirements.md): minimum and recommended hardware; which models fit which memory.
- [`provider/cli-reference.md`](provider/cli-reference.md): every `darkbloom` subcommand, flag, path, and runtime constant.
- [`provider/attestation.md`](provider/attestation.md): trust levels from the operator's side.
- [`provider/direct-mode.md`](provider/direct-mode.md): serve a local OpenAI-compatible endpoint without the coordinator.
- [`provider/self-route.md`](provider/self-route.md): pin your own API traffic to your own provider.
- [`provider/fan-control.md`](provider/fan-control.md): the opt-in root fan helper.
- [`provider/beta-features.md`](provider/beta-features.md): `darkbloom beta` toggles and retired flags.
- [`provider/troubleshooting.md`](provider/troubleshooting.md): symptom → check → fix.

## Developer how-tos

- [`developer/build.md`](developer/build.md): build the coordinator, sidecar, provider, and UIs; toolchain pins.
- [`developer/test.md`](developer/test.md): every test suite, what CI runs, how to run the e2e suite.
- [`developer/release.md`](developer/release.md): cut a provider release — version bump, signing, notarization, hashing, registration.

## Operations runbooks (production; human approval per mutation)

- [`operations/README.md`](operations/README.md): index and the two rules that apply to every runbook.
- [`operations/coordinator-deploy.md`](operations/coordinator-deploy.md): swap the production coordinator to a reviewed build, verify, roll back.
- [`operations/dev-environment.md`](operations/dev-environment.md): the GCP dev environment.
- [`operations/model-migration.md`](operations/model-migration.md): publish a model build and move an alias with zero downtime.
- [`operations/release-policy-rollout.md`](operations/release-policy-rollout.md): shadow-then-enforce rollout of the release-policy routing gate.
- [`operations/routing-v2-rollout.md`](operations/routing-v2-rollout.md): kill switches for the shipped routing-v2 behaviours.
- [`operations/state-export.md`](operations/state-export.md): extract and rehydrate sealed coordinator state.

## Records (frozen)

- [`design/README.md`](design/README.md): plans and decisions, each with a status saying whether it shipped.
- [`reports/README.md`](reports/README.md): dated incident analyses, measurements, and migration records.
- [`releases/v0.8.0-notes.md`](releases/v0.8.0-notes.md): the v0.8.0 notes, kept as the record of the paged-KV release that v0.8.1 reverted; current history is `CHANGELOG.md` at the repository root.

## Legal

- [`legal/privacy-policy.md`](legal/privacy-policy.md): privacy policy as published.
- [`legal/terms-of-service.md`](legal/terms-of-service.md): terms of service as published.

## Layout

| Directory | Page type | Frozen? |
|---|---|---|
| `consumer/`, `provider/`, `developer/` | how-to | no |
| `operations/` | runbook | no |
| `reference/` | reference | no |
| `architecture/` | explanation | no |
| `design/` | design record (status line only may change) | body frozen |
| `reports/` | dated record | yes |
| `releases/` | release notes | yes |
| `legal/` | policy text | as published |
| `assets/` | diagrams (`.mmd` source + rendered SVG/PNG), CSVs | — |
| `.private/` | internal drafts, not documentation | — |

`make docs-check` lints every page (stamp, links, cited paths, orphans);
`make docs-stamp FILES=docs/path.md` refreshes a stamp. Details in
[`AGENTS.md`](AGENTS.md).
