# Segmented paging follows the admitted slot grant

> Last updated: 2026-09-05 · commit `02f6af71a`

Production segmented paging now receives the provider's normal admitted KV
grant and follows subsequent shrink/grow updates. The obsolete fixed-pool
policy and its tests are deleted. Native construction starts without pages;
existing admission, allocator, model-load and OS-headroom checks still apply.

## Problem and change

The old factory reduced a slot grant by useful context demand, a physical-RAM
fraction, live-headroom fraction and an 8 GiB ceiling, then required a minimum
pool. For the exact Qwen3.5/3.6 geometry, B1's 32,768-token demand at 20,480 bytes
per token is 640 MiB, below that 1 GiB minimum. Explicit paged selection could
therefore fail before the first request despite an ample admitted slot grant.
The bridge also clamped regrowth to the backend's previous capacity.

`makeSegmentedPagedBackend` now passes the admitted grant into empty native
segmented storage. It retains observed per-layer dtypes, window/prefill geometry,
per-buffer Metal limits and checked native page addressability. The 64 MiB
segment target is a maximum size-class target, not a mandatory allocation or
an eager reservation of the entire grant. Native Admission reserves physical
growth before allocation and retains live obligations across shrink.

The bridge identifies segmented storage through the engine's capacity contract
and forwards its new admission ceiling. Committed bytes remain separately
visible; shrink does not claim to have freed live buffers. Explicit fixed-slab
reference backends retain their clamp/shortfall diagnostics for native fixtures.
The production factory no longer constructs those reference pools.

Unified-memory caps, loaded weights, serving-set activation reserves, operator
reserve, fair-share reslicing, minimum useful KV and post-load OS/headroom gates
are unchanged. The rollout default remains contiguous.

## Validation

Accepted provider evidence covers **503 unique functions and 510 cases**, with
zero failures or skips. Candidate2 directly runs the full 97-test factory group.
The other 14 groups ran on candidate1 (406 functions/413 cases); their source is
unchanged. The only candidate1→2 delta corrects the GPT factory fixture to
require the full grant and zero committed bytes, segments and address pages.
Candidate2's build took 102.25 seconds.

Eight new tests exercise actual native construction and Admission with exact
five-artifact geometry and deliberately synthetic capacity inputs. They cover
B1/B2/B4, 36/64/128 GiB envelopes, sub-GiB and above-8-GiB grants, native mixed
dtypes, window rings, normal Qwen recurrent/MTP promises, exact refusal
boundaries, shared process competitors, live OS headroom, borrowers and
shrink/retirement/regrowth. Existing three-way reslice tests cover three slots.
These loops are not counted as extra framework cases or physical machine tests.

The live co-residency fixture retains real load/stream/unload behavior and now
checks mutable grants on both backends. Its old FP16-based oversized request
probes were removed because they mispriced actual GPT storage. This fixture
compiled but did not execute in this unit gate; exact live capacity remains a
release requirement.

Root verified both attempts' 189 payloads, 61 owned paths, 675 provider inputs,
480 native inputs, 1,356 dependency inputs and 27 Jinja inputs. It applied the
canonical 16-path delta, including two deletions, and verified every resulting
owned source hash against the accepted build. Native engine
`aafe2069bcdeadef9250530eb511c598649c0355` remains unchanged.

## Evidence and remaining work

The [manifest](evidence/segmented-production-grant-2026-09-05/manifest.json) and
[archive](evidence/segmented-production-grant-2026-09-05/payloads.tar.gz) retain
194 payloads, including the original failed factory expectation,
corrected test, complete execution scopes, source graphs and root checks.
Manifest SHA-256: `59737f6f366d280790e6ed436b99a0acb286604ccbe098a796cacaa7eb94bf01`.
Archive SHA-256: `aefa5c4ea0e38db8bf774e9978f5b64e8c6c1b3eaad2fcf42513538e109be1d0`.
Accepted validation manifest: `073d71e553c4dcac67ed8ccee4cf0fdda5ab10890d52276f851fb5d121ee1cc7`.

Production-grant benchmark derivation, the final standalone/HTTP binaries,
exact-model normal-MTP correctness, capacity and repeated latency, connected
coordinator routing, and signed persistent restart remain required. This commit
does not establish a speedup or release completion.

Related: [provider integration](2026-09-05-paged-complete-provider.md),
[memory policy](../architecture/hardware-support.md),
[prefix caching](../architecture/prefix-cache.md).
