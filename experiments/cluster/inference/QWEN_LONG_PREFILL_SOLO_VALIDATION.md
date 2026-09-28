# Registered Qwen 8K solo prefill validation

> Last updated: 2026-09-14 · commit `e4df336bc`

One fresh full-model Qwen3.5-9B request completed on a 24 GiB M4 Pro. Its final
state and BF16 logit metadata/digests and selected token matched the separately
frozen [8K reference](QWEN_LONG_PREFILL_REFERENCE_VALIDATION.md). The unchanged
prospective CPU oracle, provenance audit and separate process postflight passed.
The measured first-token interval is a single diagnostic observation; it does
not establish stable throughput or a cluster speedup.

| Executed control | Value |
|---|---|
| Hardware | One M4 Pro, Mac16,7, 14 CPU / 20 GPU cores, 24 GiB; macOS 26.6.2 build 25G83 |
| Model | Registered 32-layer Qwen3.5-9B; complete verified model; stored quantization preserved; MTP disabled |
| Workload | `long_prefill_8k_v1`; batch 1; 8,192 input tokens; 512-token chunks; one output; no teacher tokens or decode forward |
| Input | Same pinned generated English prose with repeated paragraphs; no added special tokens or chat template; not a representative workload claim |
| Execution | `qwen-long-prefill-solo-check`; `cbv2-contiguous`; native BF16; one process; one request; zero warmups; seed 7 |
| Arithmetic | Query block 128; BF16 policy 1; TF32 permission 1; `MLX_METAL_GPU_ARCH` and `MLX_SDPA_BLOCKS` absent |
| Completion | Native exit 0; exactly loaded-ready/report records; 102,824 stdout bytes; empty stderr; clean request retirement and weak model-release checks |

The [solo coordinator](Sources/ClusterInference/QwenLongPrefillSoloCheck.swift)
loads the verified model before ready. The
[request owner](Sources/ClusterInference/QwenLongPrefillSoloRequest.swift)
admits that source, emits ready, then starts the monotonic clock immediately
before fresh `CBv2RequestSession` construction. The interval includes
16 forwards, evaluated state roots and commits, bounded commit metadata, native
complete-row finiteness/argmax and scalar token readback. It excludes model
loading, initial source admission, ready output, final numerical captures and
retirement. The final state and logit metadata are captured once after stop;
there are no per-frame numerical snapshots. No reference forward runs in this
timed process and no candidate/reference comparison occurs inside native code.

The solo interval was **18,605,041,167 ns (18.605041167 s)**, giving
**440.310770 input tokens per first-token second**. Its separate post-stop
interval through request close was 115,989,791 ns; outer model release and cache
clearing followed. The CPU oracle checks exact UInt64 arithmetic and the Double
rate formula. Clock placement remains bound to source, without per-phase
profiler timestamps.

| Chronological diagnostic observation | First-token interval | Input tokens / interval |
|---|---:|---:|
| 1. Two loopback ranks, `serial_v1` | 18.812326166 s | 435.459173 tokens/s |
| 2. Two loopback ranks, `prompt_lookahead_one_v1` | 18.569559000 s | 441.152103 tokens/s |
| 3. One complete-model process, solo | 18.605041167 s | 440.310770 tokens/s |

All three used the same executable, prompt, arithmetic policy and single GPU,
with fresh processes in this fixed order. The rank intervals also include
transport, scalar action traces and context source admission. There were no
counterbalanced repeats or resident warmups; driver/cache state, launch order
and normal variation remain uncontrolled. These differences do not isolate
transport cost, GPU overlap or causal scheduling gains. See the
[rank path](QWEN_LONG_PREFILL_RANKS.md) for its distinct clock boundaries.

| Independently checked final evidence | Solo result |
|---|---|
| Source inventory | 927 canonical text tensors; 5,038,041,600 logical bytes |
| Request | Fresh UUID consistent across ready/history/selection; 16 commits; frontier 8,192 |
| Complete final state | 72 entries; 319,946,784 logical bytes |
| State fingerprint | `59659ed425cfadf4e184fcb8533f4c9fd16a4311f37b83df3f06fa48911009f6` |
| Final logit row | BF16 `[1,248320]`; 496,640 logical bytes |
| Logit SHA-256 | `4dea769bd622b97b34a914e2c488ffe599701884561f1a42b1d4ee9dfde6dfe6` |
| Selected token | 271; reference maximum 21.25, unique maximum |

The oracle reconstructs the reference's full BF16 row from exported Float values,
including signed zero. Candidate values are not exported: their metadata and
digest agree, without an independently reconstructed candidate row or direct
native-byte comparison. All state metadata and digests match; only eight Int32
offset digests can be reconstructed. The other 64 numerical state digests remain
opaque. Native loading, finite selection, commits, fresh ownership and release
remain assertions bound to the archived source and executable. The source-created
request UUID differs from the reference; there is no external rank epoch.

| Saved resource observation | Value |
|---|---:|
| Initial actual-free bytes | 10,362,716,160 |
| Post-hash actual-free / estimated-reclaimable bytes | 10,054,778,880 / 17,945,870,336 |
| Pressure/swap samples | 24; pressure 1; zero reported swap throughout |
| Native RSS observations / largest sample | 19 / 5,795,168,256 bytes |
| Reported MLX peak since process start | 6,500,375,576 bytes |
| Active / cached MLX after request close, weights resident | 5,038,440,976 / 4,121,872,732 bytes |
| Active / cached MLX after model release and cache clear | 4,016 / 0 bytes |

The initial actual-free gate was 6 GiB; the post-hash estimated-reclaimable gate
was 8 GiB. Pressure at most two, zero reported swap, a 300-second native
deadline and a 330-second parent deadline remained enforced. These observations
are not memory-safety guarantees. RSS is sampled, not a peak; missing samples
are not zero, and raw `ps` text was not retained. The cumulative MLX peak has a
different scope from RSS and does not bound all active plus cached allocations.
The 745,345,056-byte named-tensor admission estimate excludes weights and native
workspaces. Postflight observed pressure one, zero swap and no owned live
processes. The local SSH client was reaped; remote `waitpid` is not independently
proven.

The 50-test numerical oracle and 18-test launcher were frozen before this run;
the 15-test provenance verifier was frozen before candidate access and applied
unchanged. The archive binds 300 source files, dependency declarations, bundle,
exact arguments/environment, raw prompt and origin, saved artifact controls and
output/resource records. Remote full-artifact checks remain pinned-control
attestations; tokenization and the native build are not independently reproduced.
No later live-tree state is substituted for the retained archive.

The shared executable SHA-256 is
`a47a93d4bab9382d03c79769e06dee2152f1204043035a47cba875ca0c09da60`;
its source-manifest SHA-256 is
`68dea3f5cff28eb641c31512b16d97eec046fbd692b58fcafd4f3bba4125c168`.
The commit stamp identifies the base; this archive binds the experimental source.

| Retained solo evidence | SHA-256 |
|---|---|
| Launcher receipt | `4f8f98c9bdfb39d58ac9e1ce1027ecfc86dc6ae322963fe5b9f0e25b30395680` |
| Independent CPU audit | `b1473d9625e528501d4be686386bcd0f20a55918b7f219a8b77f5ccd984a0d11` |
| Provenance audit | `e4742931354579669c15bd3a44d0bbc3756cf58468b533277128686c9246ade9` |
| Separate postflight | `b6c3fc6f3d7286c24467b5a75138afd89cee125623d1a6c8efebeb951bf35395` |
| Native stdout | `2e4b6f707d87484fdd389d160890861a33707c992885495414e94c601f14d963` |
| Frozen numerical helper | `a1fb84e449279f09a7b4c21165f9863ed83084e84728435d83c32171f8cad1f4` |

This validates the bounded 9B solo control. It does not qualify decode
continuation, physical Thunderbolt/RDMA, 27B inference, M3 Ultra performance or
the [800 TPS distributed prefill target](../../../docs/design/distributed-inference-goal.md).
The [solo contract](QWEN_LONG_PREFILL_SOLO.md) describes the implementation.
