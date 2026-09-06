# GPT-OSS and Gemma QAT default HTTP smoke

> Last updated: 2026-09-06 · commit `2eebb5412`

Both exact release artifacts passed the final-candidate B1 default HTTP smoke. Configuration requested `engine_v2_kv_backend=auto` and `mtp_mode=auto`, with no global prefix-cache override or assistant override. Both actually loaded paged attention without a fallback, disabled SSD prefix caching (`config_disabled`, no cache capability), and performed ordinary generation with MTP inactive and zero MTP rounds.

| Exact model ID | Requests | Prompt + completion = total tokens, each request | Observed backend | SSD / MTP |
| --- | --- | --- | --- | --- |
| `gpt-oss-20b` | Cold + repeat, both passed | 5,454 + 64 = 5,518 | paged, no fallback | off / inactive |
| `gemma-4-26b-qat-4bit` | Cold + repeat, both passed | 5,399 + 64 = 5,463 | paged, no fallback | off / inactive |

For each model, the two HTTP responses matched in content, reasoning, tool fields, finish reason and positive, consistent prompt/completion/total counts. All four requests had observed engine batch width 1, zero SSD lookups/hits/donations, and zero cached or saved-prefill tokens. HTTP exposed the `length` finish reason at the 64-token cap. Runtime profiles explicitly reported MTP inactive. Generated configuration was checked and its contents are excluded from this capsule.

Both runs exited successfully. The caller, supervisor, owned worker and recorded detached Go group completed with retirement receipts. Fresh postflight observations found no provider, model runner or other owned/foreign workload. Canonical host configuration hashes matched before and after; each exact model's ten manifest files and runtime identities were verified before and after. The M5 lane was released after QAT completed.

The exact artifact/contract/input hashes, raw-report hashes, source/runtime/Go identities, output hashes, counts and retirement projections are in [evidence projection](evidence/gpt-qat-default-http-2026-09-06/evidence.json). The projection was independently recomputed from the retained raw reports and cleanup receipts. It includes no prompts, output text, provider-configuration contents, credentials, binaries or weights.

Runtime pins:

- Provider: `a98b9a83a69ab90a59010437f2a567341d7f8a98853a83cab8deea1043540433`
- Metal library: `20972c37e53fe6db3b3191a0434f6604c4ffc4f5ac62b370574f9922585b0fdb`
- Go test executable: `cdbde019a9cf1db44ca82afd728727968517d2c36f84e3fd3081c7dbd70f0506`
- Go source receipt, including the dirty overlay: `b02928cd6463ecc91831c0d0b444487b11d056b4a80c5e199bf3f15bec636cb2`

This is a bounded default-selection and repeat-consistency result: one provider, two sequential text requests per model, temperature 0, seed 0 and a 64-token cap. HTTP does not expose raw generated token IDs. B2/B4, multimodal/tools requests, cancellation/restart, multi-provider routing, model quality and release-wide readiness remain outside this result. Qwen defaults and explicit Gemma MTP-on serial verification are separate validations. Ephemeral fixture keys were used; persistent signing, keychain and package-distribution behavior were outside scope.

Observed HTTP elapsed times were 3.679/1.950 seconds for GPT-OSS and 3.113/2.007 seconds for QAT. These first/repeat measurements are descriptive and establish no sustained-performance claim.

The [capsule](evidence/gpt-qat-default-http-2026-09-06/evidence.tar.gz) and [manifest](evidence/gpt-qat-default-http-2026-09-06/manifest.json) retain the original share-safe projection. The [candidate build record](2026-09-06-release090-candidate-build.md) binds the compiled numerical and activation fixes.
