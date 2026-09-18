# Bounded native attention packets at the ordinary decode boundary

> Last updated: 2026-09-06 · commit `384c321aa`

The diagnostic can capture one selected attention owner's original Q, incoming
K/V, post-update stored K/V and returned output in their native dtypes. Native
and benchmark validation pass without source corrections. An optimized packet
probe and real target-model capture remain pending; numerical parity is not established.

## Capture and ownership

The default-nil packet configuration independently selects a request, generated
output position and dense storage owner. It uses the bound concrete cache identity
introduced by native `e972340a7ba6e22fda5d8be1a7af918f9bf67b03`, preserving the
original model indices on contiguous production caches. Metadata and logit
diagnostics retain their own configurations and bindings.

The supported scope is ordinary MTP-off B1/L1 text decode with one full-attention
owner, complete visible history, no shared KV, sinks, softcap or spans. A
conservative FP32 reservation bounds all supported native payloads before array
retention or paged gather. Native bytes are capped at 32 MiB. Unsupported geometry
or budgets produce an explicit inconclusive diagnostic, not a new serving limit.

The actual post-normalization/post-RoPE Q remains unchanged. Contiguous capture
keeps native stored K/V before attention-view widening. Paged capture uses the
existing ordinary gather and its write/read dependency. The six original handles
join the selected step's existing evaluation targets. That step blocks its chained
successor, including when the selected step is itself a chained decode.

Existing sample confirmation and normal step-cost accounting precede host copies.
A nonblocking Cmlx availability query must report every original handle available
before `asData(.copy)`, whose internal evaluation therefore cannot schedule a
pending packet graph. An unfenced handle is refused. Forward defer clears concrete
bindings; retirement, discard, failed forward, drain and shutdown release tensor
handles. Only packed host-owned bytes remain for idle export.

## Export and telemetry

The benchmark writes the agreed `darkbloom.attention-packet.v1` format: one hashed
raw metadata snapshot, six hashed native buffers and their packed shapes/strides.
Identity contains the verified loaded model aggregate hash and the hash of the
same input bytes parsed by the benchmark. Executable identity stays in run evidence.
The descriptor is written last into a fresh private directory.

The summary distinguishes captured, refused and unconfirmed work and records
reserved bytes and diagnostic scope. Gather work, the successor barrier and host
copies are diagnostic overhead; these timings are not release performance evidence.

## Validation

Thirteen native filters pass: **77 functions / 162 expanded cases**, including
12 new packet functions / 29 cases. Coverage includes FP16/BF16/FP32 roundtrips,
original wider queries, D256/QH16/KVH2 geometry and the final partial partition
beyond 4,096 tokens. Expected stored bytes are independently assembled from known
history and incoming rows. An adversarial subsequent overwrite and actual page
recycling preserve captured bytes. Pending graphs and unconfirmed work cannot export.

Actual engine tests compare direct/chained controls across contiguous, fixed and
segmented backends. Generated tokens, ordinary forward shapes and recurrent staging
remain equal. BF16 captures pass the availability guard. The next actual forward
observes that packet arrays have retired. Simultaneous and independent metadata,
logit and packet selections pass, as do selected cancellation and typed forward
failure cleanup. Existing owner, metadata, logit, recurrent, dtype, kernel and
segment suites also pass.

Five benchmark filters pass **18 functions**, including four new packet option and
export tests. They verify exact native bytes, metadata hashes, identity, private
directory creation, and refusal of incomplete, unconfirmed or unverified packets.
Fourteen Python wrapper tests pass. No tests are skipped or source corrections
made during validation. Native and benchmark builds take 58.77 and 90.07 seconds.

Verification covers 907 native, 683 provider and 19 harness compile inputs,
1,356 dependency files and 27 Jinja files. The retained build graphs match 771
native and 1,023 benchmark declared source references. These counts do not claim
every graph entry links into the selected product. Pinned availability, byte-copy
and asyncEval implementation sources are identified explicitly; an unused remote
SwiftPM checkout does not supply the compiled MLX source.

## Evidence and remaining work

The [manifest](evidence/attention-packet-capture-2026-09-06/manifest.json) and
[archive](evidence/attention-packet-capture-2026-09-06/payloads.tar.gz) retain
169 rehashed payloads, 6,784,188 uncompressed bytes. The archive is 3,064,146 bytes.
Compiled binaries and model weights are excluded.

Manifest SHA-256: `9bfc7875857bc69b386b545907305b38d80de13b4ad58e3deb52b6cddfc51b03`.
Archive SHA-256: `f76c2f42c168f5fac8ec9c3f19446342c0adef19529f20206a3d22a2b39903dd`.

The offline FP32 analyzer is banked separately. Real target packets must still be
collected with their own unchanged-output controls. Same-input native backend
replay and an independent history mirror remain separate proof requirements.
This milestone does not resolve the Qwen output difference, establish a speedup,
enable cache defaults or declare release readiness.
