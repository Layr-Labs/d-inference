# Registered 27B: one-stage loading and later 8K memory gates

2026-09-14. Source/retained-metadata calculation only; no model payload, new
header, candidate output, compiler, native execution or resource observation was
accessed. `ledger.json` pins the source and shared retained inventory. Bytes below
are decimal integers; GiB means 1,073,741,824 bytes.

The first executable increment is one default 32-layer stage in a fresh process,
followed by release. Its exact logical loaded tensor total is **7,566,416,384 B**.
There is no source-proven whole-process memory minimum. Live admission must add
fixed operational headroom to actual allocator bounds and can still refuse or
fail. Do not authorize 8K prefill from a successful loading-only gate.

| Term | Stage 0: layers 0..<32 | Stage 1: layers 32..<64 |
|---|---:|---:|
| Active canonical tensor count | 923 | 924 |
| Active stored/loaded tensor bytes | 7,566,395,904 | 7,566,406,144 |
| Logical BF16 inert placeholders | 20,480 | 10,240 |
| Active plus inert logical bytes | 7,566,416,384 | 7,566,416,384 |
| Stored-to-loaded dtype expansion | 0 | 0 |
| Largest selected host copy | 635,699,200 | 635,699,200 |
| Loaded logical bytes plus one largest host copy | 8,202,115,584 | 8,202,115,584 |

The 1,847 full text tensors total 15,132,802,048 B: 13,446,676,480 B U32 and
1,686,125,568 B BF16. No stored F16/F32 tensors occur. Lazy constructor floating
defaults being F32 does not establish a resident second full set of weights.
Inert placeholders are logical allowances; their allocation is not independently
established. The 16,320,415,757 B manifest total is verified storage, including
excluded components and metadata, not resident text weight memory.

`VerifiedQwenLayerStageLoading` materializes one selected tensor at a time. Its
`TensorDescriptor.read` creates CPU `Data`, copies into MLX-owned storage, then
the loader evaluates, synchronizes, checks unique contiguous buffer metadata,
and installs that array. The native copy contributes to the final active tensor
sum; counting it again on top of that full sum would double-count it. One host
copy is a conservative named allowance independent of lexical loading order,
not a measured simultaneous peak. Lazy graph objects, autorelease behavior,
allocator cache, framework metadata and filesystem cache remain additional.

The allocator bound includes alignment **and larger cached-buffer reuse**.
For the conditional Metal policy with a 16,384-byte page, each nonzero tensor
uses `a + min(a-1,32767)`, where `a=n` for `n<=16384` and otherwise page-rounded
`n`. Summing that bound over every selected active and inert tensor yields
**7,590,359,139 B** for either stage, 23,942,755 B above the logical sum. Native
admission must obtain the actual allocator policy and derive checked bounds;
this example does not observe the target's page size or allocator state.

Root's updated requirement supersedes the earlier proposal based on reclaimable
memory: actual free must be at least **max(6 GiB, the remaining selected
allocation/copy/headroom requirement)**, initially and at prescribed progress
checks. Reclaimable is reported only. If the chosen remaining formula is
`R + 2H + 4 GiB`, the conditional initial actual-free threshold is
**13,156,724,835 B**; its exact final formula belongs to the new source gate.
The corresponding proposed allocator increment `R + H + 2 GiB` is
10,373,541,987 B, in addition to observed active/cache bytes. Never raise an
allocator limit to force admission. The earlier 2,345,140,224 B actual-free
proposal is rejected and must not be used. Reserve constants are policy choices,
not measured scratch bounds. Hashing can consume file-cache headroom, so the
live gate must occur after verification and immediately before materialization.

For later 8192/512/1 prefill, each half has 8 attention and 24 GDN layers. At
frontier8192 its 72 native BF16/F32/Int32 state entries total **345,407,520 B**.
Full KV rows reserve capacity8193, so native capacity plus one recurrent
generation and offsets is **345,440,288 B**. One BF16 boundary is 5,242,880 B.
The existing conservative named formula separately gives **826,806,304 B**:
536,936,480 KV/offset bytes at F32, 235,339,776 for three recurrent generations,
33,558,528 for one host state component and 20,971,520 for two F32 boundaries.
Do not add the native-state subtotal again to that formula.

GDN first-use fusion evaluates concatenated weights/scales/biases and replaces
named source modules with views. Each half's 24 banks sum **1,139,097,600 B**;
one bank is 47,462,400 B. Treat the full sum as a replacement/cache-overlap
allowance, not proven permanently duplicated weights. Adding loaded logical
bytes, one host tensor, this allowance and the named state formula yields
**10,168,019,488 B per process**, or **20,336,038,976 B** for two independent
rank processes, before rounding and unmeasured reserves. This remains a partial
ledger, not a safe physical-memory threshold.

Attention and GDN intermediates are not covered by that sum. For example, one
logical attention score array at query block128 and key length8192 has
`24*128*8192` elements: 50,331,648 B at BF16 or 100,663,296 B at F32. Four query
blocks do not prove four simultaneous copies or a single-copy peak. Actual
dispatch, temporary lifetimes, synchronization, allocator retention, final
selection/evidence and system memory need separate qualification. The existing
9B 745,345,056 B/768 MiB admission and legacy 6 GiB source/512 MiB host/8 GiB
manifest caps stay unchanged; the new metadata resource plan never grants a
runtime permit. The catalog's `apple_m5`/`mlx_nax` requirements and unqualified
M3 forward arithmetic are separate from successful metadata or weight loading.
