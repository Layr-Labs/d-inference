# Onboard Laya System One decisions

> Last updated: 2026-09-22 · commit `ce809b792`

Runbook for publishing the pinned English Laya checkpoint and enabling native
decision inference. Local runtime qualification, provider release, coordinator
deployment, model registration, pricing, and public alias activation are separate
steps; completing one does not establish the others.

## When to use

Use this procedure for the initial 421M FP16 English Laya checkpoint. Its native
endpoint is `POST /v1/systemone`; chat, completions, messages, and responses are
not supported for this model. See the [consumer guide](../consumer/system-one.md)
for request shapes and limits.

## Prerequisites

- Reviewed native decision changes in the coordinator, provider, and pinned
  `libs/mlx-swift-lm` dependency. The provider must advertise the per-model
  `system_one` capability; an older provider version alone is not sufficient.
- Passing native numerical parity, local HTTP, encrypted transport, lifecycle,
  cancellation, model-integrity, and zero-output accounting checks.
- A signed and qualified provider build and a reviewed coordinator image.
  Follow [provider release](provider-release.md),
  [App Attest build qualification](app-attest-build-qualification.md), and
  [coordinator deployment](coordinator-deploy.md).
- Explicit approval for each production upload, registry/pricing mutation,
  deployment, and traffic activation, as required by the repository's production
  operation policy. Prepare exact artifacts and registration payloads first.

## Steps

1. Download and verify the immutable checkpoint locally:

   ```sh
   hf download aac6fef/laya-mlx \
     --revision 20aed815fc6acde75733882e7ec0e3f28aeb9717 \
     --local-dir /path/to/laya-mlx
   hf cache verify aac6fef/laya-mlx \
     --revision 20aed815fc6acde75733882e7ec0e3f28aeb9717 \
     --local-dir /path/to/laya-mlx --fail-on-missing-files
   ```

   Preserve the original nested encoder and tokenizer directories. The weight
   SHA-256 is `b9c07bf14be2fa5c78a9193a3e6d840ac80e89e62fc40f425834c3d8a6eaa3de`.
   The weights occupy 842,609,225 bytes; model-file size is not the serving
   memory requirement. Retain the source Apache-2.0 license and notices.

2. Build the native probe and run numerical qualification against the pinned
   Python MLX reference. Follow the module's
   [runtime and parity guide](../../libs/mlx-swift-lm/Libraries/MLXDecisions/README.md).
   Record source revisions, checkpoint revision, hardware, toolchain,
   source-matched metallib, precision, question counts, sequence lengths, and
   observed error/latency ranges.

3. Generate the Darkbloom manifest offline, outside the downloaded directory:

   ```sh
   cd provider-swift
   swift run darkbloom-publish hash /path/to/laya-mlx \
     --id aac6fef/laya-mlx --version 2026-09-21-r1 \
     --output /path/to/laya-manifest.json
   ```

   Verify that the manifest covers weights, `mlx_config.json`,
   `rl_agent_config.json`, `encoder/config.json`, both tokenizer files, and the
   original `LICENSE` and `NOTICE`. The [prepared eight-file manifest](../assets/laya/manifest.json)
   has aggregate SHA-256 `1c9dacab4be23506e8b182ba5aaeb5ac608e73627d369e96396db0774b2ade20`.
   The scanner recognizes the native format through
   `provider-swift/Sources/ProviderCoreFoundation/LayaModelLayout.swift`
   (`LayaModelLayout.isSupported`); it does not invent a chat template.

4. Prepare the registration payload with these endpoint-defining values:

   The reviewable [registration draft](../assets/laya/registration-draft.json)
   keeps promotion disabled. The [alias draft](../assets/laya/alias-draft.json)
   keeps the alias inactive. Neither file has been submitted by this runbook.

   | Field | Value |
   |---|---|
   | Model/build ID | `aac6fef/laya-mlx` |
   | Public alias after qualification | `laya` |
   | Architecture | `laya` |
   | Capabilities | `["system_one"]` |
   | Quantization | `fp16` |
   | Maximum context length | `512` per independent question |
   | Maximum output length | `0` |
   | Output price | `0` |
   | Input price | Provisional `10000` micro-USD per million encoded input tokens ($0.01), selected for the draft |
   | Hugging Face artifact | `{"repo_id":"aac6fef/laya-mlx","revision":"20aed815fc6acde75733882e7ec0e3f28aeb9717"}` |
   | Minimum RAM | Conservative 16 GiB pilot floor in the draft; local runtime evidence is from a 128 GiB M4 Max, so qualify the intended minimum hardware before activation |

   These values are checked by `coordinator/api/system_one_catalog.go`
   (`validateSystemOneDefinition`) and registration validation. Token usage
   repeats state for each question and excludes batch padding; it is not the
   token count of the state alone. Do not assign chat/tool/reasoning capabilities
   or a made-up output-token allowance.

   Existing billing floors remain: direct accounts have a 100 micro-USD
   ($0.0001) request minimum; service accounts retain their existing rounding
   policy; owned self-routing is free. Resolve the intended minimum for short
   decision requests with the provisional input price before activation.

5. Exercise the complete flow on the [dev environment](dev-environment.md),
   including one attested provider with the exact release artifact. Verify
   mixed decisions, encrypted transport, cancellation, zero completion tokens,
   input billing, rejection on old providers, and recovery after model unload.

6. After the specific operations are approved, publish immutable artifacts and
   register the build without promoting it. Use the publication and registration
   steps in [model migration](model-migration.md), supplying the pinned HF
   artifact and native registration values above. Deploy the approved
   coordinator image and qualified provider release through their runbooks.

7. Canary the native build with selected providers and real System One requests.
   Activate the public `laya` alias only after the canary passes. Confirm the
   model is discoverable as a decision model and absent from the OpenRouter
   generation feed.

## Verification

- `POST /v1/systemone` returns matching answer keys and question types, finite
  probabilities, the requested model alias, positive input usage and zero
  output usage.
- A chat-family model on System One, and Laya on a generation endpoint, are
  rejected before inference. Missing native provider capability prevents routing.
- Admission limits and request cancellation leave no busy owners, pending loads,
  ledger reservations, or model-slot state after completion.
- Laya uses exclusive model residency for the initial implementation. A busy
  chat slot cannot be evicted to admit it, and a cancelled decision retains
  ownership until its submitted GPU work has finished.
- Preserve full rollback identities and distinguish source/test results from
  signed-build qualification, deployment, and observed live requests.

## Rollback

Disable native traffic through the existing model status/shed controls before
reverting the coordinator or provider artifacts. Deactivate the public alias or
build as appropriate; do not point it at a chat model. Restore approved images
and provider versions using their release runbooks, then verify existing chat
traffic independently. Retain the immutable checkpoint and manifests for audit.

## Related

- [Consumer System One guide](../consumer/system-one.md)
- [Inference architecture](../architecture/inference.md)
- [Model migration and publication](model-migration.md)
- [Provider hardware requirements](../provider/hardware-requirements.md)
