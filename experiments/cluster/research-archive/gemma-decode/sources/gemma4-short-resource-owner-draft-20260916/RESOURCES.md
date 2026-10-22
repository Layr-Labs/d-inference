# Allocation lifetimes and operational ledger

Let `U(x)` be the actual native allocator's one-buffer upper bound. `R` is the sum of `U(selectedBytes)` for all uncompleted tensors; the current authorized tensor remains in `R`. `H` is the largest selected logical tensor, `C=U(H)`, and `S` is the existing aligned reader scratch bound. `N` is the sum of separately rounded named arrays. `E` is bounded host correctness evidence. While reads remain:

- required actual-free = max(6 GiB, R + H + C + S + N + E + 4 GiB)
- required allocator limit = actual active + actual cache + R + C + N + 2 GiB

After payload replacement, R/H/C/S become zero. N/E and both operational headroom terms remain charged through probe, request and retirement. Existing active allocations are not subtracted from these conservative future-reserve terms. Cache must be zero; reclaimable memory never authorizes work.

`tensor.read(.all)` retains its native original array and aligned read temporaries while an F16 source is converted to BF16. Before-read does not retire a reservation. The new after-tensor callback runs only after the autoreleasepool that owns `read`, `read.array`, conversion and update temporaries has exited; only then does completed advance. A duplicate, skipped, substituted or incomplete callback poisons the owner. Parameter replacement never evaluates the old constructor graph.

| Logical term (bytes) | Full | Stage 0 | Stage 1 |
| --- | ---: | ---: | ---: |
| Exact selected source payload | 14,467,688,508 | 5,093,977,620 | 9,788,946,984 |
| Persistent projection F32 cast caches | 3,061,780,480 | 1,019,392,000 | 2,042,388,480 |
| Tied head transient F32 casts | 92,274,688 | 0 | 92,274,688 |
| F32-ceiling actual full/window KV capacity | 420,823,040 | 151,273,472 | 269,549,568 |
| All named allocation requests, before rounding | 4,813,046,632 | 1,604,526,072 | 3,209,061,232 |
| Bounded host correctness evidence | 18,825,216 | 8,798,208 | 13,533,184 |

The 1,339/450/892 payload allocations and 2,564/862/1,705 named arrays are rounded separately by the real native API. These logical rows must not be presented as measured native admission thresholds.

`ConstantArrayCastCache` retains one BF16-to-F32 conversion and its source descriptor per quantized projection parameter/current stream. Probe forward can populate those caches; they survive probe-cache destruction and stay charged until the loaded model is released. The source snapshot pins an already-accounted original buffer. The tied output embedding does not use this cache; its possible F32 scales/bias conversions receive a separate transient charge. Ingress embedding only gathers the selected packed rows and group scales/biases. The narrow entry rejects arithmetic/cache/prefill overrides whose alternate allocation path is not this scope.

Named arrays also cover ring capacity and conservative old-ring/chunk views, all selected layers' major attention/shared-FFN/router/sort/expert outputs, three-token probe rows, residual copies, final row and host snapshot exports. Routing uses all 128 stored experts and top8 selected assignments; no source expert slicing is enabled. Every layer's named intermediates are charged concurrently; default async evaluation or global29 tail narrowing earns no discount. At this P32/O2 scope the logical attention view is at most 34 rows even though a sliding cache allocates 1,024 slots. The native SDPA two-pass length thresholds are therefore not reached. This does not establish coverage for longer requests, other kernel paths, or all native workspace.

The native allocator's observed peak is not OS whole-process physical footprint. Future native reports must retain both observations if OS lifetime peak is available, plus raw parent resource samples. A short successful run can qualify this exact correctness scope; it cannot establish a general MoE serving floor.

## Candidate split selection

The metadata calculator supports any sealed partition; only the operational owner binds cut10. Dynamic source-to-local mapping replays every retained cut15 destination and each candidate's exact all-cuts count/bytes. The table uses logical allocation sizes (U(x)=x), so actual rounded admission can be larger. These are prospective load thresholds, not observed free memory.

| Cut | Ingress weights B | Ingress persistent casts B | Ingress all named arrays B | Initial ingress actual-free logical floor B | Initial follower actual-free logical floor B |
| --- | ---: | ---: | ---: | ---: | ---: |
| 8 | 4,159,851,536 | 815,874,048 | 1,274,220,448 | 10,483,325,872 | 19,318,657,012 |
| 10 (selected) | 5,093,977,620 | 1,019,392,000 | 1,604,526,072 | 11,748,871,692 | 18,053,111,192 |
| 12 | 6,036,214,808 | 1,224,712,192 | 1,887,080,528 | 12,974,498,920 | 16,827,483,964 |
| 15 | 7,437,403,934 | 1,529,989,120 | 2,382,538,964 | 14,872,817,650 | 14,929,165,234 |

Given the root's approximate current24GB actual-free observation (about13.8GB), cut10 provides more margin than12 while reducing follower work relative to8. This is a correctness candidate, not an optimal-performance choice or guarantee of admission. The actual whole-model48GB logical floor is24,341,130,148B; root must obtain fresh actual resources before that reference too. Neither approximate host observation is encoded as an admission input.
