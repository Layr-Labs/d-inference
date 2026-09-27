# Reviewed connected cache inputs, revision 2

> Last updated: 2026-09-05 · commit `9e49059a1`

Revision 2 prepares all five exact model pairs with the corrected Gemma assistant
directory and SSE reasoning reader. Root independently verified the frozen
package and approved owned staging. All ten cells were unrun at package freeze;
this report records preparation, with no new model or final HTTP pass claim.

The Gemma override now names `gemma-assistant-local-override1`, containing only
the same verified config and safetensors bytes. Its catalog manifest stays
outside the directory. The launcher checks the actual declared path, exact flat
membership, regular non-symlink files, sizes and hashes before launch. Production
assistant compatibility and MTP-active guards still apply. Exact-copy, preflight
and post-pair byte proofs are retained; the original initialization failure is
preserved in the [initial pair report](2026-09-05-initial-paged-ssd-pairs.md).

The Go executable uses all 988 source/resource files from `089d9ade3`, including
the [SSE alias correction](2026-09-05-connected-reasoning-aliases.md). Build
before/after manifests and a full banked-source comparison match. Its SHA-256 is
`6e30a1e53cc26ac1bb7953216b6d0af835b8b08a29f1920b2df07999c0e2bc8f`.
The provider CLI remains `a81fd9f9ff01fb84f3c236ceaba5fed4fca730b261be1f332b87c38e69cd3cfd`
with native `aafe2069bcdeadef9250530eb511c598649c0355`. It does **not** contain
the [new MTP output-budget policy](2026-09-05-mtp-output-budget.md).

All ten inputs were regenerated for `090-connected-http2`. Only the Gemma
assistant path and applicable vision paths changed in model inputs; each off/SSD
pair is identical except `cache_mode`. Exact artifacts, runtime hashes, authored
prompt/tools and normal MTP modes are unchanged. Fifteen Python helper tests and
five local CPU prompt plans passed: Qwen3.6/Qwen3.5 5,503 tokens, Qwen3.8 5,545,
GPT-OSS 5,454 and Gemma 5,399. The exact Go executable's earlier helper run passed
12 functions and 18 subtests; packaging did not rebuild or rerun those checks.

The request-owned date is 2026-09-05 UTC. Rollover requires newly generated,
reviewed paired inputs and CPU plans; no clock or frozen-input override is valid.
Root verified 1,070 payloads, 1,071 regular archive members, all 988 Go files and
all five input pairs. All 1,034 original package payloads remained unchanged.
The fixture remains B1, two provider processes and two tenants on one Mac.
Normal Qwen3.5 parity, final-runtime HTTP, B2/B4, independent-machine behavior
and persistent restart remain separate gates. No GPU or remote work ran during
this revision's local preparation or this evidence milestone.

The [evidence manifest](evidence/connected-cache-inputs-revision2-2026-09-05/manifest.json)
and [evidence archive](evidence/connected-cache-inputs-revision2-2026-09-05/payloads.tar.gz)
retain inputs, helpers, tests, reviews, assistant proofs and build provenance.
The compiled executable and duplicated 988-source tree are excluded; exact
hashes remain pinned. The complete runtime-package archive has SHA-256
`8906188e5631c392242c6b60ddfe1a72090140ab74ffeedb0c01021cd0d0dee0`;
its package manifest is `2af7b2ac59d0200e466b9ef4c2c39fef085156fe8c24152b27b571e18e02acc2`.
The unchanged [original package](2026-09-05-connected-cache-inputs.md) has archive
SHA-256 `af94f9460f034b457b216dedb7678d174979a6c10b52325133c9743a72bf9363`.

Related: [connected validation procedure](../developer/test.md#connected-coordinatorprovider-http-cache-gate).
