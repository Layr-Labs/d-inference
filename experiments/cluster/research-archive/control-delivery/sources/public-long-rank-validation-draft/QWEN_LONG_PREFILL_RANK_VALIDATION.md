# Registered Qwen 8K rank prefill validation

> Last updated: 2026-09-14 · commit `e4df336bc`

Two fresh two-process Qwen3.5-9B runs completed on one 24 GiB M4 Pro: first
`serial_v1`, then `prompt_lookahead_one_v1`. Both passed the unchanged prospective
CPU oracle, archive/provenance verification and separate process postflight.
Their complete final-state metadata/digests, final BF16 logit metadata/digest and
selected token matched the [8K full-model reference](QWEN_LONG_PREFILL_REFERENCE_VALIDATION.md).
The runs used the same executable and GPU, with loopback transport between ranks.
They do not establish physical Thunderbolt/RDMA operation or a scheduling speedup.

| Property | Executed value |
|---|---|
| Host | One M4 Pro, Mac16,7, 14 CPU / 20 GPU cores, 24 GiB; macOS 26.6.2 build 25G83 |
| Model ownership | Registered 32-layer Qwen3.5-9B; layers 0–15 on rank 0 and 16–31 on rank 1; MTP disabled |
| Workload | `long_prefill_8k_v1`; batch 1; 8,192 input tokens; chunk size 512; output count 1; no teacher tokens or decode forward |
| Input | Same pinned generated English prose with repeated paragraphs; first 8,192 of 16,385 tokenizer IDs; no chat template or added special tokens |
| Execution | `cbv2-contiguous`; native BF16 residuals/logits; `ring` backend with explicit `loopback-test` transport |
| Arithmetic | Query block 128, BF16 policy 1, TF32 permission 1; `MLX_METAL_GPU_ARCH` and `MLX_SDPA_BLOCKS` absent |
| Repetitions | One fresh cohort per policy, in the order above; zero warmups; seed 7 |
| Completion | Both native ranks exited 0 in each cohort; exactly ready/report JSONL records per rank; only the admitted loopback warning on native stderr |

Each rank's ready record follows verified stage loading and the exact peer
readiness exchange, before fresh request-state creation. The native
[request owner](Sources/ClusterInference/QwenLongPrefillRankRequest.swift) then
executes 16 boundary transfers and 32 stage commits per cohort. Each residual is
BF16 `[1,512,4096]`, or 4,194,304 logical bytes. The terminal reports retain
`correctnessOnly=true`, `throughputMeasurementValid=false` and
`physicalTransferQualified=false`.

| Rank-zero diagnostic | Serial | Lookahead one |
|---|---:|---:|
| Origin interval, nanoseconds | 18,812,326,166 | 18,569,559,000 |
| Origin interval, seconds | 18.812326166 | 18.569559000 |
| Input tokens / first-token interval | 435.459173 tokens/s | 441.152103 tokens/s |
| Post-stop through request close | 61,735,042 ns | 61,563,500 ns |
| Preparations before prior consumed drain | 0 | 15 |

The origin monotonic clock starts immediately before start-packet send and fresh
context creation. It includes context admission, stage work, boundary validation
and copies, scalar trace recording, final finite argmax and token return. It
stops after the final consumed acknowledgement and selected-token validation.
Readiness and model loading precede the clock. Post-stop release, final diagnostic
captures and request retirement follow it; outer model release is later still.
The CPU oracle checks UInt64 interval arithmetic and the exact Double rate
formula. Clock placement and phase observations remain tied to the archived
source, without independent per-phase profiler timestamps.

These are single observations from fresh processes sharing one GPU. The policies
ran in a fixed order with no counterbalancing or resident warmup. Cache state,
launch order and ordinary variation are uncontrolled. The difference does not
identify a causal scheduling gain, stable throughput or a two-machine speedup.
No solo timing result is part of this record.

The frozen oracle passed 82 prospective CPU tests before native execution and
was applied unchanged. It independently derives the admitted request/history,
all 16 frames, 204 sender actions and 235 receiver actions. The lookahead trace
places the next preparation after original-wrapper release and before the prior
consumed drain; the next header waits for that drain. The serial trace prepares
after the prior drain. Each rank's native weak-reference checks report release
of 16 original boundary wrappers. This is not proof that storage has no aliases
or that GPU kernels overlapped. Successful reports follow clean request
retirement and weak model-release checks.

The two actual stage inventories conserve 927 canonical text tensors:
463 / 464 tensors and 2,519,016,704 / 2,519,024,896 active logical bytes.
The separately checked inert parameters total 16,384 / 8,192 bytes. The registered
checkpoint has another 364 excluded vision/MTP header entries. Its retained source
contains no Float16 tensors, so the enabled BF16 conversion policy converted none.

| Numerical comparison | Both cohorts |
|---|---|
| Complete final state | 36 entries per rank; disjoint union 72; 319,946,784 logical bytes |
| Final state fingerprint | `59659ed425cfadf4e184fcb8533f4c9fd16a4311f37b83df3f06fa48911009f6` |
| Final logits | BF16 `[1,248320]`; 496,640 logical bytes |
| Final logit SHA-256 | `4dea769bd622b97b34a914e2c488ffe599701884561f1a42b1d4ee9dfde6dfe6` |
| Selected token | 271; reference maximum 21.25, unique first-index maximum |
| Captures | No per-frame state/logit captures; one final state capture per rank; one final logit capture and native token selection on rank 1 |

The reference's full BF16 row is reconstructed from exported Float values,
including signed zero. Candidate logit values are not exported: their metadata
and digest agree with the reference, without a direct native-byte comparison.
All state shapes, dtypes, byte counts and the combined fingerprint are checked;
only eight Int32 offset digests are reconstructable. The remaining 64 numerical
state digests and all 16 boundary payload digests expose no raw values. There is
no independent second model forward. Native loading, finite selection, commits,
release and retirement remain assertions bound to executable/source provenance.

Within each cohort, both ranks exported identical exact v4 boundary envelopes
and the final token packet. The oracle checks those encoded bytes against the
locally admitted source/input/frame identities. Domain fingerprints remain
distinct from SHA-256 of raw encoded bytes. Ready/received/consumed and post-stop
ACK byte hashes are independently derived expectations; actual ACK bytes and
readiness/start payloads are not exported. Fresh cohort identities make wire
hashes differ between policies even when numerical digests agree.

| Final wire identity | Serial | Lookahead one |
|---|---|---|
| Boundary domain fingerprint | `f81f485e797c47fc31095b0ccf9c44feddfea37e74e07b3f7c62bbce86b165d8` | `977a3420976d218fed335c997df6efa78e14e1d7b7efb5582c22547291ec66c1` |
| Boundary raw-byte SHA-256 | `d769c7c9e4335b7262c730592a66924c0e34dc4390e9d97757ed2dff616a0ea2` | `3fa015202e831532d8301e172de8785a9261df108302ae312cd8e4535bbdbe19` |
| Token domain fingerprint | `a78cf024bade17c6bfdef177fd80b2d2818ca79148a4cb715fef8c75dfceb410` | `f25f2ba3fa133ab03448df613d0ca6f2f2caa8ea5e039f2fbbad0913f6613bc5` |
| Token raw-byte SHA-256 | `5aaf0efea3543afb813be014718aa59d32713d2064ab3ba2bdfacd713df5a021` | `ba5f26741410e04e3f87ad86dbd7d74ac73d0c9c0ca99854b333871de744a3cf` |

The resource controls passed the initial actual-free screen of at least 6 GiB
before bundle/model reads and the post-hash estimated-reclaimable screen of at
least 8 GiB. They enforced pressure at most 2, zero reported new swap, a
300-second native deadline and a 330-second parent deadline. Available memory at
those screens is not a guarantee of memory available throughout execution.

| Saved resource observation | Serial | Lookahead one |
|---|---:|---:|
| Initial actual-free bytes | 9,098,526,720 | 9,680,863,232 |
| Post-hash actual-free bytes | 8,813,756,416 | 9,355,198,464 |
| Post-hash estimated-reclaimable bytes | 16,164,438,016 | 17,922,850,816 |
| Pressure/swap observations | 23; pressure 1; zero reported swap increase | 24; pressure 1; zero reported swap increase |
| Native RSS observations per rank | 19 / 19 | 20 / 20 |
| Largest sampled native RSS, rank 0 / rank 1 | 3,206,512,640 / 3,204,923,392 bytes | 3,249,553,408 / 3,249,553,408 bytes |
| Largest sum from a sample containing both native ranks | 6,407,208,960 bytes | 6,499,106,816 bytes |
| Reported MLX peak since process start, rank 0 / rank 1 | 3,593,964,284 / 3,598,166,770 bytes | 3,593,964,284 / 3,598,166,770 bytes |
| Active MLX after model release/cache clear, rank 0 / rank 1 | 2,016 / 2,008 bytes | 2,016 / 2,008 bytes |
| Cached MLX after model release/cache clear | 0 / 0 bytes | 0 / 0 bytes |

The RSS values are sparse source-bound observations, not process peaks; missing
samples are not zero. Native sums exclude the supervisors. Saved RSS units and
ownership were checked, but raw `ps` text was not retained for independent
reconstruction. No ordering across process-local monotonic clocks is inferred.
MLX peaks and cached allocations have different scope from RSS. After request
retirement but before model release, each rank still reported about 2.519 GB
active and 3.462–3.467 GB cached; the peak column is not a bound on all those
allocations or whole-process memory. The 745,345,056-byte named-tensor admission
estimate under its 768 MiB ceiling excludes weights and native workspaces.

The 22-test launcher and 13-test provenance verifier were frozen prospectively.
Both completed archive audits bind 300 source files, dependencies, bundle,
arguments, input origins, raw rank output, saved full-artifact controls and
resource observations. Their scope is the frozen archive, not the later live
tree or a reproduced build. Raw prompt/origin hashes were checked without
rerunning tokenization; remote full-artifact checks remain saved pinned-control
attestations. Each separate postflight reported pressure 1, zero reported swap
and no matching owned remote processes. Local SSH clients were reaped;
independent remote `waitpid` proof is not asserted.

Both cohorts used executable SHA-256
`a47a93d4bab9382d03c79769e06dee2152f1204043035a47cba875ca0c09da60`
and source-manifest SHA-256
`68dea3f5cff28eb641c31512b16d97eec046fbd692b58fcafd4f3bba4125c168`.
The commit stamp identifies the repository base; the archive manifest binds the
tested experimental source. The separately frozen full-model reference used its
own archived executable, documented in the reference validation.

| Retained evidence | Serial SHA-256 | Lookahead SHA-256 |
|---|---|---|
| Launcher receipt | `4e5b015b619a35e7e261f0bd45c6954406f42eaabd8f9a11da592a44e3e470d9` | `17de7244b91234a0752c1b673fe61fc8f6584b4cd201933925bc2af6b5772711` |
| CPU audit execution receipt | `791c0a35ca5231efbc8263b3c267177c75627f30cb6e63bdf57ab9015cd64503` | `3f7eebc6cef8f7c7691de9a0d1498a8370735ab1c84feb659837d03469c0092c` |
| Provenance audit | `a8ab1796cdf8be2bbe8e9f3f217ee0fcad6ecf1cb0c322c39f596e8888dfea95` | `0af364fd2df497403baa43a479aeb4e9f2cd70e2f961ec30d6f1f8a787173efd` |
| Root postflight | `7c8d0b79bda572d2bd94d10d9eb793eb43e82611fa690ca17795c6a315273d9c` | `e42ad9c7b5e2ee9f0c050d91a04fd748d763ea90b4c61ac0902c85062457e31d` |

| Shared control | SHA-256 |
|---|---|
| Raw prompt, 38,405 bytes | `ee6caf0be6391e00ec41df930f0fd6351613969622cbb247b1b4bdaf69afe997` |
| Registered artifact aggregate | `127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b` |
| Frozen full-model reference stdout | `da85eb1e79a43c16575e6a8ffd48594ccb72306c16543a1e02c24903b89c154a` |
| Frozen rank CPU helper | `2507438e3fd2557809ba08298ce62144713ec9c438f64c00824f4ccffc1a649c` |
| CPU test receipt, 82 passed | `4123858c5719d098adab598ecdbd493f7312512bf467ee71519f7967ed7fd614` |

This record qualifies neither physical two-machine execution, decode
continuation, 27B execution nor M3 Ultra performance. See the
[inference experiments](README.md) and
[distributed inference goal](../../../docs/design/distributed-inference-goal.md).
