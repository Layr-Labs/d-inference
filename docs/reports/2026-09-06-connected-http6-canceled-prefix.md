# Connected SSD cancellation and recovery preserve native cache usage

> Last updated: 2026-09-06 · commit `6790dea1c`

Qwen3.8 passes all ten cache-off cases, all ten SSD cases and the unchanged
strict HTTP pair comparison. Cancellation now records actual SSD reuse and its
accepted lookup before one terminal; subsequent recovery and sidecar outage
also pass. The earlier [HTTP5 failure](2026-09-06-connected-http5-cache-and-cancel.md)
remains retained separately.

## Actual cancellation and routing

The canceled SSD request has 5,552 prompt tokens, 4,096 cached tokens and 4,096
prefill tokens saved. It bills one completion/reasoning token after the client
receives content and cancels. Exactly one native hit lookup precedes exactly one
provider completion; coordinator accepted lookup and hit counters each increase
by one. The profile records cancellation received at 1,847,479 microseconds and
aborted at 1,847,638 microseconds, during decode. This closes the real-model
HTTP regression behind the [native settlement handoff](2026-09-06-canceled-prefix-settlement.md).
Staging estimates alone are not used as hit evidence.

The donor, same-prompt repeat, tenant isolation, continuation on provider B,
original prompt after continuation, tools, vision, cancellation, recovery and
sidecar-unavailable cases all pass in order. The repeat, original prompt after
continuation and recovery each report 4,096 tokens actually restored from SSD.
The other tenant and the continuation on provider B stay cold; routing returns
the original prompt to an existing holder. Tools return the expected call and
arguments. Vision and sidecar outage remain cold-only requests. Normal MTP is
observed in provider profiles.

The unchanged `e2e/connected_cache_evidence_test.go` gates native usage, encrypted
dispatch, accepted coordinator receipts, correlated routing and cancellation.
The unchanged pair comparator verifies served content, reasoning, decoded tool
calls, finish reasons and token usage. Cancellation lengths remain transport
dependent under the original oracle; native adoption, partial delivery and one
terminal are still required. No wire events are dropped.

## Paired first-content observations

| Case | Cache off, seconds | SSD, seconds | SSD staging, milliseconds | Tokens saved |
|---|---:|---:|---:|---:|
| same_prompt_a | 6.546 | 1.890 | 137.673 | 4,096 |
| original_after_continuation | 6.781 | 1.881 | 131.822 | 4,096 |
| cancel | 6.648 | 1.855 | 122.903 | 4,096 |
| after_cancel | 6.808 | 1.874 | 132.254 | 4,096 |

These are individual HTTP first-content observations from one sequential pair,
not repeated performance estimates or decode measurements. The full fixture
lasts 113.884 seconds cache-off and 159.297 seconds with SSD, including setup,
cold controls and waits for durable donations. The first-content improvements
above do not imply the whole fixture became faster.

## Exact runtime and retained host checks

Two provider processes and two authenticated tenants run on one M5 Max with
128 GiB memory: paged backend, B1, normal MTP, SSD tier and isolated ephemeral
cache keys. This is the production encrypted HTTP/WS path in the existing test
fixture, with candidate membership controlled to exercise holder selection.
It does not prove independent-machine routing or persistent-key restart.

The CLI is built from parent `98103b39741a48f9d47026be7393362318a2ab0a`
and native `dcf39f6b43effaa2b483211c97d7d3a3e7c0269b`, including the cancellation
handoff and bounded attention diagnostics. CLI SHA-256 is
`e27c1e51c8d4fc71e031748ebcb6b3372a6dee9d4c3eca38b17e063972db7b0c`.
Six runtime resources retain build8 bytes and modes. The unchanged Go executable
is `6e30a1e53cc26ac1bb7953216b6d0af835b8b08a29f1920b2df07999c0e2bc8f`;
all 988 Go source/resource files match the reviewed primary tree. Root verifies
the final 1,182-file package, runtime artifacts and exact input pair. Only the
provider binary/path/hash and owned vision path differ from HTTP5 requests.
The two current inputs differ only in cache mode; CPU tokenization remains exact.
Twenty package helper tests pass locally and on M5; five focused controller
checks pass locally and in independent root review.

The cache-off native/Go run completes successfully, but the outer controller
returns failure when it reuses the entry-temperature guard after completion:
47.007 degrees C exceeds 42 degrees C. The raw refusal is preserved. Independent
strict assessment passes every case, with no owned jobs left. A fresh guard
passes at 31.163 degrees C before SSD starts. The SSD run and its postflight
both pass, with no owned jobs and GPU temperature 41.433 degrees C. No hot-start
waiver, cache-off rerun, source change or oracle relaxation is applied.

## Frozen evidence and remaining scope

The [manifest](evidence/connected-http6-canceled-prefix-2026-09-06/manifest.json)
and [archive](evidence/connected-http6-canceled-prefix-2026-09-06/payloads.tar.gz)
retain 337 verified payloads, including both raw runs, strict comparison,
cancellation ordering, source/runtime/input identity, transfer modes, helper
tests, independent reviews and the original postflight refusal. Runtime binaries,
weights and key material are excluded; their exact identities remain recorded.

Manifest SHA-256: `c303990d0a0847ab95c3291a3b81cfdd455961f49d5ac2996ed3d9c3c015fcad`.
Archive SHA-256: `a1db048628055fd88aa30be92822c1e1d49bab99ba1221bf4ceef3fcb08caec8`
(8,072,538 bytes).

This result covers one artifact, one host, B1 and one cache-mode pair. Other
models, repeated concurrency/capacity cohorts, independent machines,
persistent-key restart, strict contiguous/paged parity and final release
promotion remain separate gates. It does not measure the later namespace patch
or claim a broad decode improvement.
