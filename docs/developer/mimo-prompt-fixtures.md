# MiMo prompt fixture reproduction

> Last updated: 2026-09-28 · commit `b6f9574ed`

The Rust MiMo parity tests intentionally require pinned metadata and an
independent20-case corpus. Missing inputs are failures, not silently skipped
checks. No model weights, API credential or running inference service is needed.

Set `MIMO_PROMPT_ARTIFACT_DIRECTORY` to a metadata-only directory and
`MIMO_PROMPT_REFERENCE_VECTORS` to the unchanged20-case JSON file. Both must
be ordinary bounded files, not symlinks. Validate these exact SHA-256 values:

| Input | SHA-256 |
|---|---|
| config.json | `61bea4a0f7a0dd8969f8cae528761e26b697dd12ff63e98804c3f0945492e621` |
| tokenizer.json | `ff15eb925890d6b71b5160de4b846fbd13178438ab463b38ecc953e8cd1dcb3e` |
| tokenizer_config.json | `413a7845f52943ccf4de0e5c838414507d16c44dbf573da9e20bc8902b384d06` |
| chat_template.jinja | `853650bee57bf95020373e4c928bd5a4b41b9915adf964a77711d2b49a291887` |
| Additional20 corpus | `66e6a49a23509fbc99e5389fa4687f2b6175f96d05d7a8be0f323bf4986049bb` |
| Original31 identity recorded inside corpus | `c11b2d3a9400bbe935c33f86b1ec6dc0ed91ea6e8b85030d355a4b66d35c2e8e` |

Run the existing `cargo test --locked` from the Rust sidecar after supplying
those variables and its pinned toolchain. Use a canonical temporary directory
or the test-root canonicalization correction; macOS temporary-directory aliases
must not accidentally test the production symlink refusal instead of the
intended parser/planner assertion. Keep the production refusal unchanged.

The fixture contract lives in
`coordinator/promptsidecar/src/mimo_v26/tests.rs` (`corpus`, `Fixture::new`).
The metadata cap is128MiB/file; the corpus cap is1MiB and exactly20 cases.
Do not regenerate/reorder goldens, substitute moving tokenizer metadata or
reinterpret the original31 cross-runtime mismatches as passes.

Observed execution history:118 unit passes/7 missing-fixture failures;
then122 passes/3 temporary-root identity failures with fixtures;
then125 unit plus27 integration/binary passes (152 total,0 failed/ignored)
after test-only canonicalization.
The original failing binary also passed those three cases when only its
temporary-directory path was canonicalized. Retain all attempts separately.
This is not full API/media/end-to-end qualification.

Public fixture redistribution/retrieval must retain applicable licenses and
the exact hashes above; this page neither embeds private diagnostics nor
authorizes a network/model download.
