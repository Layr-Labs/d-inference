# Exact connected cache inputs and isolated launch package

> Last updated: 2026-09-05 · commit `437bea4fe`

The connected fixture has a verified executable and paired inputs for all five
exact release artifacts. CPU prompt planning and launch-helper tests pass.
Connected provider/model execution remains pending. This package requires no
compiler, database server or production credentials on the M5 test host.

## Inputs and launch behavior

The Go test executable is built from986 pinned source/resource files at
`3aa73029ef22a6292aefff005b2267856f665a3c`; root verified they remain identical
to the integrated coordinator/testbed source. Binary SHA-256 is
`bf882626959dfadeeaa8104e4715f0231d14cbfb263be0e616fd581b4024803e`.
The package reuses the exact separately verified CLI, metallib, Rust sidecar
and flat Gemma assistant. Every run verifies model/runtime/config bytes before
and after serving, with unchanged production model/assistant eligibility gates.

The authored35,273-character prompt is untruncated. Its hash is
`10982a0c99a7e612803ee7b2c8fa62f9ebfcf3de9ae34c2dde25bf8831aee896`.
Pinned local CPU sidecar planning for the coordinator-owned2026-09-05UTC date
produced these counts; actual native restoration remains a separate assertion.

| Exact artifact | Planned tokens | Normal MTP |
|---|---:|---|
| Qwen3.6 35B | 5,503 | on |
| Qwen3.5 35B | 5,503 | on |
| Qwen3.8 27B | 5,545 | on |
| GPT-OSS20B | 5,454 | off |
| Gemma4 26B8-bit | 5,399 | on, verified flat assistant |

All five tool inputs use ordinary `tool_choice: auto` with an explicit authored
instruction and exact actual call/argument assertions. The earlier generic
forced-tool wording in the harness report was too broad: these are auto-tool
execution tests. Qwen/GPT lack the named-constraint capability, and this exact
Gemma template differs from the pinned constrained-tool contract. Named-choice
HTTP400 controls remain unrun and are not covered by these inputs.

Qwen3.5/3.6 snapshots live outside the scanner's usual discovery root. The
reviewed helper creates temporary aliases only when the corresponding model root
is absent, after verifying every manifest file and rechecking host idleness.
Exclusive creation, a random ownership marker and a retained journal identify
owned entries. Cleanup checks unchanged markers/symlinks and refuses foreign
entries; it only unlinks owned links and removes empty directories. It never
rewrites model data, host configuration, daemon installation or keys.

The launcher uses a fresh process group and output/cache roots. It refuses
inherited cache/numerical/resource overrides and stale UTC dates. It preserves
partial reports and drains only its owned group on interruption or abnormal Go
exit, including test timeout. An already-empty group receives no signal. Existing
canonical configuration is checked without repair; normal SSD testbed controls
explicitly activate isolated roots and ephemeral keys.

## Validation and limits

Nine Go helper functions pass in the compiled executable. Nine Python tests pass,
including exact alias ownership and cleanup of an interrupt-ignoring descendant
without touching another process group. Five exact CPU token plans pass. Root
verified all1,034 packaged files, the complete archive, the986 source files and
final helper hashes. The initial test-only path-alias and zombie-state cleanup
expectation failures are retained with their corrections.

This is a two-provider, two-account fixture on one Mac with B1 and sequential
requests. It does not prove independent-machine capacity or latency, B2/B4,
attestation or persistent restart. No remote discovery aliases or connected
inference were created during package preparation. The sole model-validation
lane executes the reviewed package after its current standalone cells.

## Evidence

The [manifest](evidence/connected-cache-inputs-2026-09-05/manifest.json) and
[archive](evidence/connected-cache-inputs-2026-09-05/payloads.tar.gz) retain
50 input, source-manifest, launcher, test and review payloads. The
compiled binary and duplicated986-source tree are excluded; their hashes remain
in the original package manifest. The separately stored complete runtime package
has SHA-256 `af94f9460f034b457b216dedb7678d174979a6c10b52325133c9743a72bf9363`.
Evidence manifest SHA-256: `8e1ff43194fadf2c4cddfb07c7fa95a24b2c1a8a0e73356edc1fad8492835436`.
Evidence archive SHA-256: `add0051914376001d14ed4c1369cfedb779d861b11616ea6875cc4e0bd65c53f`.

Related: [connected procedure](../developer/test.md#connected-coordinatorprovider-http-cache-gate),
[harness implementation](2026-09-05-connected-cache-http.md).
