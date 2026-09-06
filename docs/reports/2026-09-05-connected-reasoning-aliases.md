# Connected HTTP reasoning alias correction

> Last updated: 2026-09-05 · commit `0a9fb484a`

The first real Qwen3.8 connected cache-off run stopped because the test reader
duplicated equivalent SSE reasoning aliases. Its donor and repeat actually
contain identical reasoning. The reader correction passes focused and race
tests, including replay of the original bytes. A new complete HTTP pair remains
required; the failed run is preserved.

## Failure and correction

The isolated test launched a coordinator and two real providers with exact
artifact/runtime hashes, normal MTP, explicit paged storage and cache disabled.
The cold donor and same-prompt repeat completed. The equality assertion at
`e2e/connected_cache_http_test.go` stopped execution before the remaining eight
cases; the SSD companion was held. Owned processes retired and postflight
completed. No production configuration, key or daemon was changed.

Raw SSE supplies `reasoning_content` and `reasoning` as equal compatibility
aliases. `connectedStream.acceptSSE` appended both. Identical reasoning arrived
in 19 chunks for the donor and 17 chunks for the repeat, so duplicated fragments
interleaved differently. Independently reading either alias once produces the
same 385-character reasoning and empty content in both requests.

The reader now uses optional strings to distinguish absent/null aliases from
present empty values. It appends one supplied value, requires equal values when
both are non-null, and returns an error on conflict. Content, usage, finish and
tool-call parsing retain their existing behavior. Exact output comparison is
unchanged; no tolerance or normalization was added.

## Validation

Three new functions cover either alias, matching/empty/absent/null values,
conflicts including empty versus nonempty values, and the captured 19-/17-chunk
replay. All three functions and six relevant subcases fail against the original
reader. The corrected focused and race runs each pass 12 functions and 18
subtests with zero skips or failures.

Root verified all 15 frozen payloads, raw Go test counts and the exact three
source paths. The replay fixture is byte-identical to the original report's SSE
fields; an independent reconstruction confirms equal reasoning. The original
report hash is
`dd1b4b6ec61e29296696e26231d4555e28d52a52dc65dfd829856ec756b40663`.
The test fix does not turn that partial run into a completed HTTP gate.

The [manifest](evidence/connected-reasoning-aliases-2026-09-05/manifest.json) and
[archive](evidence/connected-reasoning-aliases-2026-09-05/payloads.tar.gz) preserve
17 payloads totaling 439,014 bytes: source, negative/focused/race logs, original
HTTP failure and postflight, raw replay, alias analysis and root verification.
No executable or model checkpoint is included.

Manifest SHA-256: `40e24e09ce7b9ca785b7681cb5a21d0d58b04f923276c7dc6c8969d5ae3f83d6`.
Archive SHA-256: `bb7c16a6b071130bcf18b66bc1076e98668a898a74fba82fbf491cd52dada5e1`.

A fresh connected executable and input package must include this reader and
the corrected external Gemma assistant layout before new paired execution.
The original frozen package remains unchanged.

Related: [initial model pairs and Gemma fixture](2026-09-05-initial-paged-ssd-pairs.md),
[connected harness](2026-09-05-connected-cache-http.md),
[test procedure](../developer/test.md#prefix-cache-benchmark-validation).
