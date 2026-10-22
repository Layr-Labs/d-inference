# Changelog

Unreleased changes live in [`changelog.d/`](changelog.d/README.md). Ordinary
pull requests add one fragment; release preparation alone updates this file.

Version sections identify source included in published tags, not coordinator
or console deployment, feature activation, model promotion or hardware
qualification. Sections marked historical retain the original candidate's
qualification, opt-in and deployment limits rather than claiming activation.

## v0.10.0 — candidate (unpublished)

Prepared on 2026-10-22; tagging and publication are separate steps.

### Upgrade and rollout notes

- Request normalization moves from v8 to v9 for every model, so every `prompt_contract_id` changes. A coordinator attaches a cache scope only when a provider's advertised contract matches its own, so a 0.10.0 provider under a v8 coordinator, or an older provider under a v9 coordinator, serves coordinator requests without prefix-cache or prompt-token reuse and without cache-aware routing until both run v9. Ordinary serving continues across the mismatch. Run this release with a v9 coordinator, add v9 tuples to the coordinator's cache-routing allowlist, and expect existing prefix caches to start cold.
- MLX moves from `cb77239b` to `ad4745a2` both in `libs/mlx` and in the copy nested in `libs/mlx-swift` that Cmlx compiles; `libs/mlx-swift` moves from `6923a80f` to `67dc7528` and `libs/mlx-swift-lm` from `14661d9b` to `7bed8216`. The quantized and NAX Metal kernels that every quantized model uses change, so the release metallib changes and the first start after updating compiles kernels again.
- Flint, Nemotron 3.5 Super and GLM-5.3-Flash serve coordinator requests only after each model is published and registered. Register Super only behind a coordinator that enforces its provider-version floor at 0.10.0, and GLM-5.3-Flash only behind one that requires the `glm5_next_v1` capability; without those gates a coordinator would route them without their load quotations, prompt contracts and media estimates. Flint needs the coordinator's v9 Flint prompt framing, and older providers cannot serve it.
- Two changes listed under GLM-5.3-Flash native prerequisites apply to every model: model-weight hashing reads around the file cache, and a request refused because the Mac's serving concurrency is full gets HTTP 503 before any response headers.
- `darkbloom start` does not forward these rollback switches to the LaunchAgent, so they affect only foreground processes: `DARKBLOOM_TTFT_FUSED_CAUSAL_PREFILL`, `DARKBLOOM_TTFT_QWEN_MTP_CHAINED`, `DARKBLOOM_TTFT_QWEN_MTP_CARRY`, `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB`, `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS` and the `DARKBLOOM_NEMOTRON_SUPER_*` settings.

### Native Flint support

- Add native Recursive Flint loading and CBv2 serving for the official group-64 affine INT4 artifact with INT8 embeddings and native BF16 KV. Live KV and checkpoint precision must both be native.
- Enforce the loaded artifact context limit for prompt plus reserved output before request admission.
- Preserve automatic reasoning, separate reasoning output, validate complete schema-aware tool frames and retain nulls in tool history. Media and unrepresentable raw `</arg_value>` history return errors; Flint OpenRouter parameters below covers reasoning controls, `stop` and JSON `response_format`.
- Enforce native reasoning/tool boundaries in every Flint request, including requests without tools, with split-token marker handling, EOS protection and prepared tool-choice/cardinality rules. JSON and schema checks remain mandatory in the parser and post-validator.
- Keep the caller's messages for required and named Flint tool choices instead of adding a generic tool-only instruction; the native constraint and validators enforce the call. This fixes paged named-tool requests that repeated a call inside unfinished reasoning until the output limit and failed. The request-normalization identity advances to v9 for all models; see Upgrade and rollout notes.
- Bound protocol state and vocabulary caches. Constraints add host/masking work; Flint serving speedups below restore chained decode. Unconstrained diagnostics do not establish production safety, answer quality or throughput.
- Omit unused prefill vocabulary projections while preserving the full trunk and every KV write. Dense/expert NAX execution is captured; a speedup and the prefill/decode targets remain unproven.
- Credit Prince Canuma's MIT mlx-vlm implementation and Recursive's Apache-2.0 rec reference, including its protocol grammar design, with full licenses retained in the SDK notices. Physical qualification remains scoped to the accompanying evidence; MTP, reduced KV and model publication are outside this change.

### Flint OpenRouter parameters

- Accept Flint reasoning effort, `reasoning.enabled` and thinking switches with no effect, since Flint always chooses whether to reason. Malformed values are still rejected. `reasoning.exclude`, `include_reasoning: false` and `reasoning.enabled: false` now hide Flint's reasoning in chat completions, the Responses API and coordinator streams; those tokens are still counted and billed, and they no longer appear in coordinator logprobs.
- Support up to four `stop` sequences on Flint, matched only against the visible answer after reasoning; reasoning and tool calls never trigger a stop.
- Enforce JSON `response_format` (`json_object` and `json_schema`) on Flint's answer after optional reasoning. Requests with tools and a response format return only the formatted answer. Output that is cut off or invalid returns 422 instead of a successful completion.

### Flint paged-only defaults

- Flint now loads on paged attention with the default provider configuration and never falls back to contiguous. An explicit contiguous selection, the paged kill switch or a paged construction failure refuses the load instead of serving the unqualified contiguous path.
- Flint now uses native KV and checkpoint precision even when the provider-wide checkpoint default is `balanced`; an explicit per-model or environment request for reduced precision is still refused.

### Flint serving speedups

- Pin the SDK with Flint decode and prefill speedups: larger decode command buffers, fewer paged decode dispatches and uploads, a fused MoE expert combine, batched sliding-window prefill attention, and constrained decode chaining. Outputs are byte-identical to the previous build.
- Flint's protocol and stop constraints keep decode pipelined: the next step no longer waits for the host to build its mask, and repeated constraint states reuse a cached device mask.
- `RecursiveSI/flint-int4` now serves at the automatic paged width (8 concurrent requests) on M5 Pro, Max and Ultra.
- The pinned SDK change edits shared paged-attention, sampler and engine-loop code, so every paged model runs it; the byte-identical output check covers Flint.

### Flint decode fusions

- Pin the SDK with exact Flint decode fusions (fused q/k/v and gate/up projections, fused routed gate/up banks, a single MoE combine-and-residual kernel and compiled router steps): about 40% fewer GPU dispatches per decode token with byte-identical outputs.

### Nemotron 3.5 Super native owner and media discovery

Staged Nemotron Super VL checkpoints no longer advertise media capability merely
because their configuration includes a vision tower; only the exact serving
identity in the next entry advertises media.

Add an unregistered native text binding with explicit LOAD recheck, bounded
calibrated prefill and request retirement ownership. Synthetic fixtures exercise
text and causal image installation through the real bridge, image cancellation
and retirement, plus live loopback HTTP authentication/SSE/restart. The image
owner binds the installation and separate media/KV reservations. Its CPU
decoder accepts PNG of every colour type and bit depth (byte-exact with the
reference loader) and baseline/progressive JPEG (ImageIO samples within
measured bounds), applies EXIF/XMP orientation as Pillow does, and bounds
declared geometry before allocation; the SDK resize is bitwise equal to CPU
PyTorch on the golden fixtures. Inline images use the `data:image/png;base64,`
or `data:image/jpeg;base64,` label; content selects the format. Image media
reservations include a derived tower and projector working-memory bound for the
largest image. The owner speculates with the embedded MTP head, verified by one
exact captured target window per round
(`DARKBLOOM_NEMOTRON_SUPER_MTP_VERIFICATION=serial` keeps one target step per
draft); synthetic fixtures show token-exact output and exact rollback in both
modes. The managed production slot in the next entry serves local and
coordinator requests through this owner and sets speculation and concurrency
itself, superseding the opt-in image hook and the
`DARKBLOOM_NEMOTRON_SUPER_MTP` and `DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT`
switches the owner first used. Full-checkpoint quality and image formats other
than PNG and JPEG remain unqualified. Portable fixture harnesses preserve reproducible
continuation and require measured admission and reservation calibration before
enabling serving.

The owner serves text as well as images. Prompts match the reference
chat template and tokenizer byte for byte on a 30-case golden corpus (tool
schemas in request order, tool-call history, images with `<img>` placeholder
spans, reasoning on/off). Reasoning follows the reference `ultra_v3` parser:
`enable_thinking` defaults on and streams `reasoning_content`. Text requests
return validated `tool_calls` and validated `response_format` JSON. Image
requests still refuse tools and structured output; image prompts carry the
reference `<img>`/`</img>` span around each image's placeholders. A request
that arrives while the owner is busy gets 429 before any response starts, and
with speculation installed image requests run target-only beside speculating
text.
Each request's reservation now includes a decode row; a KV grant too small for
the configured requests fails the load with the minimum grant it needs. The plain owner
batches text decode row-exactly, and the speculative owner (rectangular
verification) serves up to eight concurrent requests verified in one exact captured window per
round, each committing its own accepted prefix; serial verification stays one
request. `DARKBLOOM_NEMOTRON_SUPER_MTP_DEPTH=auto` lets the engine pick each
step's depth up to three. Synthetic fixtures show token-exact output against
solo plain decode. Prompts prefill in fixed chunks (`DARKBLOOM_NEMOTRON_SUPER_PREFILL_CHUNK`,
default 2048 tokens), at most one chunk per step beside every decode or verify
row, optionally with decode-only steps between chunks
(`DARKBLOOM_NEMOTRON_SUPER_DECODE_STEPS_BETWEEN_CHUNKS`); a request's chunks are
the same as when it is served alone. The prefill activation charge is one
owner-wide lane, reserved before the first request and held until retirement
(the pinned checkpoint charges the SDK's measured whole-chunk bound), instead
of a prefill workspace in every request's reservation.
`DARKBLOOM_PREFIX_CACHE_MEMORY=1` opts the owner into
exact text prefix reuse: a resident recurrent checkpoint bank sized from the KV
grant and the machine (half of what the grant leaves beside every request's
fixed bytes, the prefill lane and one image, and half of what the memory cap
leaves beside the load, at most a quarter of the grant and 16 GiB, none below
1 GiB: 16 GiB for a lone slot on 192 GB and up; or
`DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES`) whose budget is reserved from load until
retirement. The managed slot turns it on whenever that size is
non-zero. Checkpoints sit only at multiples
of the prefill chunk, where a restored request continues a cold prefill bit for
bit on synthetic fixtures; prompts shorter than one chunk restore nothing. On
the speculating owner a checkpoint also holds the assistant's prompt history, so
a restored request speculates exactly as a cold one. An image request reuses
only checkpoints bound to the same evaluated image features at the same
positions.

### Nemotron 3.5 Super served natively

- Discovers and advertises exactly `nvidia-nemotron-3.5-super`: the complete
  pinned NVIDIA NVFP4 checkpoint with its embedded MTP head. The registry id
  with an unpinned `config.json` or index is withheld; every other
  `nemotron_h_omni` id stays unsupported, as before. It advertises image and
  video input; capacity quotes for media probes charge their images' whole
  reservation, a one-part probe the larger of one image and one video.
- Loads into a shared slot through a managed owner: the ordinary eviction and
  re-slice, one LOAD claim covering the installation, the head, the
  speculating owner's round work once and the configured requests' KV
  headroom, each counted once (the load's transient only where it
  exceeds that serving room, since freed load buffers are returned before
  serving), every shard verified against its pin, an owner-wide prefill
  lane of the measured chunk peak (8.5 GiB at 2,048 tokens), a measured
  2 GiB activation reserve (its requests, lane and media
  charges hold its activations), and a refusal naming the minimum when the
  grant cannot serve every request. Defaults: exact rectangular speculation for up
  to eight requests, drafting three tokens for one decoding request, two for
  two to four and one beyond (the fastest depth measured at each width on the
  full checkpoint); `mtp_mode = "off"` or `DARKBLOOM_CBV2_MTP=0` serves the
  plain owner, and an explicit `engine_v2_max_concurrent` bounds the width.
  When available memory cannot hold that owner (a 128 GB Mac running other
  work), the load serves the widest narrower one that fits instead of
  refusing: no prefix bank, then four, two or one concurrent requests, then
  one with 1,024-token prompt chunks, with every measured bound and the full
  context kept, and logs what it chose. Super loads keep no OS reserve beyond
  3 GiB of admission slack and the 2 GiB activation reserve (a
  `memory_reserve_gb` raised above its 4 GiB default stays free), so the model
  loads with 85.6 GiB available (about 104 GiB for the default), and a
  configuration that barely fits steps down instead of losing its admission
  after the weights are installed. If memory still drops while the weights
  install (other applications swapping on a 128 GB Mac), the load keeps the
  installed weights and serves the widest narrower configuration that still
  fits instead of failing and reading the checkpoint again. The provider
  accepts, evicts for and preloads Super on that same rule: an idle
  co-resident model is evicted when that lets the planned owner (or the
  widest reachable fallback) load,
  instead of the request being accepted and then refused with 503, and a load
  that cannot fit even after evicting every idle model is refused before it
  is accepted. MLX's cached buffers are returned before the load steps down,
  the speculation round is reserved beside the KV grant rather than taken
  from it, a load whose grant beside other models cannot serve one request
  fails instead of leaving the slot loaded and serving nothing, and a
  resident slot quotes image and video probes against the memory their
  reservation actually uses. Its advertised memory is now the narrowest
  owner's LOAD size, 83.6 GiB on every Mac (was 69.8 GiB on 128 GB,
  shrinking with RAM); the coordinator's cold-load routing, which still
  subtracts the 10% load reserve, sends a cold Super load only to a 128 GB
  Mac with about 99.4 GiB available.
  Either owner reuses exact prompt prefixes when the grant holds its bank; a
  restored speculative request drafts from the same prompt history as a cold
  one, and an image turn reuses only checkpoints of the same image features.
- Coordinator and local-endpoint chat completions use the reference prompt
  template, reasoning channel, tool and structured-output validation,
  cancellation and usage of the owner. Prefix reuse is partitioned by the
  authenticated cache scope and reports no cache use. `logit_bias` and
  `logprobs` are refused with 400. Reasoning effort is `none`/`off`/`0`,
  `medium` or `high` (top-level `reasoning_effort` or `reasoning.effort`);
  other values are refused with 400. OpenRouter's
  `chat_template_kwargs.thinking` switches thinking like `enable_thinking`,
  and Responses `reasoning.summary` (`auto`, `concise`, `detailed`) is
  accepted with the full reasoning returned. `reasoning` fields the template
  cannot honor (`max_tokens`, `exclude: true`, other members unless null)
  and `chat_template_kwargs` beyond `enable_thinking`, `thinking`,
  `medium_effort`, `truncate_history_thinking` and `force_nonempty_content`
  are refused with 400 instead of being ignored.
- Coordinator tool requests whose schemas hold `{}` or boolean subschemas
  are served (they were refused with 400); the local endpoint still refuses
  a client-sent internal schema marker. `force_nonempty_content` applies to
  streamed responses too: reasoning that never closes is repeated as
  content at the end, as vLLM does. With no tools declared, a literal
  `<tool_call>` in an answer is returned as text instead of failing. A
  `seed` of 2^63 or more no longer refuses a tool request; history tool-call
  arguments that are not a JSON object, and requests with more than 4,096
  content parts, are refused with 400. Prompts keep a string's leading
  U+FEFF and add no separator before an image after text ending in CRLF,
  and reasoning markers followed by a combining mark are recognized.
- Serves inline JPEG and PNG images (`data:` URIs) on the same slot. On the
  default speculating owner each image request runs target-only, with no
  draft state, while text keeps speculating; its media reservation, including
  the largest image's tower and projector bound, is taken before decoding and
  a reservation that does not fit is refused with 503. A second concurrent
  image request gets 429. Activation overflow on the Super model saturates as
  on deployment engines instead of becoming NaN, so images whose embeddings
  exceed the text-calibrated scales are answered instead of decoding as
  `<unk>`; non-finite image features fail the request.
- Image ingress refuses with 400, before the media reservation and any
  decode, a source whose resize workspace exceeds the SDK's 256 MiB (above
  about 33 megapixels, for example 8192 × 8192, which was reserved and decoded
  first), a PNG with more than 64 compressed text or ICC chunks or more than
  16 MiB inflated from them, and a JPEG whose scans would decode a coefficient
  again. ImageIO is given only the primary JPEG image, and a request reserves
  its largest image's decode workspace once instead of once per image.
- A busy owner refuses a request with 429 once the request is decoded,
  before its prompt is planned or rendered. An answer held for validation
  (JSON content with thinking off, forced or tool-call-only answers) starts
  its stream at the first generated token, so a streamed one that fails
  validation ends with an error event instead of a 422 status. Text requests
  no longer wait while an image is prepared, and a GPU fault while checking
  image features fails the request instead of stopping the provider. An image
  body over 8 MiB, visual tokens beyond the context or an image prompt beyond
  it is refused with 400 instead of the retryable 503.
- Serves one inline MP4 or QuickTime video (`data:video/mp4;base64,` or
  `data:video/quicktime;base64,`) as the only media of a request, as NVIDIA's
  reference serving samples it: 2 frames per second, at most 256, paired into
  tubelets with each pair's timestamps in the prompt, and EVS pruning of
  redundant visual tokens at rate 0.5 (`DARKBLOOM_NEMOTRON_SUPER_VIDEO_PRUNING`,
  `0` disables). Its media reservation (at most 3.5 GiB, below one largest
  image's) is taken before any frame decodes; a second video, a video with
  images, another container, a codec other than H.264 or HEVC, frames of
  more than 8,847,360 pixels (4096 × 2160, in any shape), more than 36,000
  frames, more than 37.6 billion decoded pixels (every frame up to the last
  sampled one decodes; ten minutes of 30 fps 1080p fits), extreme aspect
  ratios and undecodable movies are refused with 400, as is a movie that
  keeps the decoder busy past its allowance (at most two minutes).
  Cancelling a video request stops waiting on its decoder at once. A
  malformed pruning rate fails the load before installing. The checkpoint's
  video embedder is now loaded, adding 3,932,160 bytes to the resident
  installation.
- Video decoding no longer crashes when a request is cancelled or its decode
  allowance runs out mid-frame: the reader was cancelled from another thread
  while a read was blocked in AVFoundation. Reads and the reader's
  cancellation now run in order on one queue, so the reader stops once the
  read in progress returns.
- A load right after a Super unload re-samples free memory for up to two
  seconds while macOS returns the unloaded pages, instead of refusing.
- A wedged Super slot leaves serving at once and retires without stalling the
  capacity refresh: its bridge shuts down before its requests drain, within
  twice the engine's 10-second shutdown timeout (past it the slot's memory
  stays charged and Super loads are refused until that retirement completes
  or the provider restarts), and the model reloads only after a 120-second
  cooldown. Until it may load again, Super requests are refused before they
  are accepted, also while the slot retires, and nothing is evicted for
  them. The owner's prefill lane, decode rows and round work count as
  resident memory in every KV grant and heartbeat, so Super and models
  beside it no longer advertise token budget the shared memory budget
  refuses.
- Plain decode steps of the Super owner commit larger Metal command buffers
  (thread-scoped limits in the pinned MLX), and full SSD prefill windows run
  batched, with tokens unchanged: one plain request decodes at 42.9 tok/s
  instead of 34.6 on the full checkpoint. Speculative rounds are unchanged.
- Prompt processing frees each Mamba layer's temporaries within the layer
  instead of at the end of the chunk, with tokens unchanged: on the M5 Ultra
  a 24K-token prompt grows MLX memory by 2.6 GiB instead of 5.6 GiB, four
  parallel 12K prompts by 5.3 instead of 9.2 GiB. Weight hashing and shard
  loading read around the file cache, so loading no longer leaves a second
  cached copy of the checkpoint resident beside the loaded weights.
- Faster on M5 GPUs, with tokens unchanged in decode: speculative rounds
  submit the verify window in parts and use the fused decode kernels, so
  one request decodes realistic prompts at 79 tok/s instead of 70 on the M5
  Ultra. Prompt processing on NAX GPUs runs the experts on dedicated NVFP4
  NAX kernels with a fused expert route and decodes the dense projections'
  weights inside the NAX GEMM, and the Mamba layers' scan runs as a chunked
  NAX kernel: 2,881 tokens/s instead of 1,556 on a 12K prompt, within the
  teacher-forced accuracy gate (top-1 78.09% vs 78.12%, perplexity 2.7275
  vs 2.7294). The runtime-compiled NAX kernels need macOS 27; earlier systems
  keep MLX's prebuilt NAX kernels.
- Serves paged attention KV only: the segmented native paged backend, charged
  by the engine's process-memory owner, with the decode rows reserved for the
  owner's lifetime. Contiguous KV is no longer supported:
  `DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND=contiguous`, any value other than
  `paged`, or `DARKBLOOM_CBV2_PAGED_KV` disabling paged KV fails the load
  before anything is installed; the owner never falls back to contiguous
  storage. Exact prefix reuse works on it: the bank keeps its own copy of a
  donor's prompt KV and a restore writes it into fresh pages.
- Serves its whole verified context, 262,144 tokens, prompt plus output (was
  16,384); the coordinator, not the provider, decides whether a long prompt's
  prefill time suits a request. The speculating owner charges each request its
  draft history per token of its own prompt and output instead of for the
  whole window, and its round work once instead of per request, so eight
  requests claim 15.7 GiB of KV headroom beside any prefix bank (was 26 GiB at
  16,384 tokens) and the default load still fits a 128 GB Mac.
- Registered for Apple M5 Max (128 GB) and M5 Ultra (`apple_m5`, at least 128 GB
  of unified memory); only 256 GB is measured on hardware.
  Coordinator-side registration remains a separate step; see Upgrade and
  rollout notes.

### GLM-5.3-Flash native prerequisites

- Add the GLM-5.3-Flash target, trained MTP, media and bounded loader, with synthetic regression coverage. Full-model qualification remains a separate gate.
- Add a low-level GLM5 tool parser with schema-aware values and response-wide validation before tool-call emission, plus loaded-model-gated prompt controls. These do not advertise function calling, constrained decoding or media support for an unqualified model.
- Recognize the chat template shipped in `EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp`, the official template with numeric attribute access written as `[0]` subscripts, so the ordinary pinned Swift-Jinja renders it without a dependency patch. It reproduces every official-template golden byte for byte.
- Price raw same-directory GLM5-Next discovery and managed loads with the raw source size plus native-copy, tokenizer and a measured `ceil(source / 32)` residual allowance, instead of disk × 1.2. The published NVFP4 artifact (181,752,181,866 bytes) therefore fits a 256 GiB Mac with the unchanged activation and minimum-KV headroom, where disk × 1.2 did not. Bounded metadata-only cache/provenance directories remain discoverable; nested integrity files and symlinks remain refused. Malformed layouts and separate-tokenizer compositions do not receive a loadable generic fallback.
- Add an explicit default-off, manifest/aggregate-pinned local GLM qualification selection; it never advertises the local download to the coordinator or changes default cohorts. It serves GLM only through its owned embedded-MTP engine, which the default `mtp_mode = "auto"` enables without any setting; target-only GLM loads, fallbacks and in-place recovery are refused, and local startup skips GLM with a message when `mtp_mode = "off"` or `DARKBLOOM_CBV2_MTP=0` disables MTP. Coordinator-connected mode sizes GLM for an enforced 262,144-token context, never the full model context. Size GLM sparse KV using its actual asymmetric FP32 rows, preserving the engine's separate three-generation KDA request charge.
- Expose retained GLM faults on local metrics (`darkbloom_glm5_next_retained_fault`, `darkbloom_glm5_next_retained_owner_objects`, `darkbloom_glm5_next_retained_resident_bytes`). An unproven GLM retirement keeps its pending-load lease, roots, ownership and activity without refund, and its unpublished bytes are excluded from fleet KV grants. A GLM slot whose unload, eviction or shutdown cannot prove retirement is charged its KV claim, keeps a frozen grant and is skipped for eviction. Other families still load and reclaim when capacity remains, but cannot grow into that memory; when the retained grant held the whole KV budget, their loads are refused.
- Load local GLM with the native serving execution policy and record it in the encrypted checkpoint identity. GLM prefill chunks and steps are each at most 2,048 tokens, with solo stripes off: paged prefill rows read each layer's latent history once instead of retaining one selected-latent read per query token, so a 2,048-token step's priced scratch fits the post-load envelope with four concurrent requests at 8K and 32K context; at the 262,144-token coordinator bound a 256 GiB host runs at most two or three. Local GLM selects its native paged KV backend automatically and refuses rather than falling back to contiguous; the encrypted SSD prefix store defaults on for the pinned GLM identity (`DARKBLOOM_PREFIX_CACHE=0` opts out). A GLM engine that refuses to activate reports the native reason, such as the step-scratch bytes needed and available, in the load error. A published GLM engine holds standing wired residency for its weights, bounded by the same safe ceiling as MiMo and released only after proven retirement; without it, 512-token prefill chunks measured 263–367 instead of 1,246 tok/s on a 256 GiB M5 Ultra. `DARKBLOOM_GLM_PERSISTENT_WIRED_RESIDENCY=0` rolls it back. On Neural-Accelerator GPUs routed-expert prefill uses the NAX expert kernel for NVFP4 banks too (real NVFP4 artifact: 1,955 instead of 1,585 tok/s at 2,048-token chunks, 1,486 instead of 1,246 at 512-token chunks; decode unchanged). Prefill chunks past position 2,048 use the native sparse-attention prefill kernel (native profiler, 8,192-token prompts at 2,048-token chunks: 2,000 instead of 1,340 tok/s; perplexity within noise, +0.018%).
- Refuse local GLM requests that exceed the enforced context with HTTP 400 before native admission, and default an omitted `max_tokens` to half that bound. Omitted sampling fields use the artifact's `generation_config.json`. `reasoning_effort` accepts `minimal`, `low`, `medium`, `high`, `xhigh` and `max`, mapped to the template's low/high/max levels as the platform does.
- Prepare GLM image input natively: the GLM prompt policy renders interleaved image parts, the vision tower runs one image at a time with fused attention on the GPU (query-tiled elsewhere; a 7,921-token image's tower drops from 28 s to 1.4 s) and checked evaluation, and the resulting causal spans carry no position state. The media reservation charges prepared pixels, the full-frame tower working set and each image's 8000-token cap. Images are served by the embedded-MTP serving engine, which accepts prepared causal media: image rows decode target-only and never reuse cached prefixes. A GLM load now requires the reviewed shipped chat template, and a selection file with the unsupported `tokenizer` field is refused.
- GLM MTP now verifies up to three drafted tokens per round in one target forward (rectangular verification, adaptive depth) by default, including with the GLM prefix cache, and sampled requests speculate through exact target-prefix acceptance. GLM MTP output is not token-identical to target-only greedy decoding: the multi-token verify forward can flip near-tie tokens. `DARKBLOOM_GLM_RECTANGULAR_VERIFY=0` restores serial single-proposal verification; the variable is forwarded to the launchd provider job.
- Reserve the GLM MTP layer's memory per request in proportion to that request's reserved tokens (a fixed amount plus bytes per token) instead of for the full model context, and price its index scratch from the actual selection path (the native sparse decode kernels pool in kernel; absorbed attention never expands selected latents). Under the serving policy with 2048-token steps and depth-3 verification this is 4.14 GB plus 33,900 bytes per reserved token, about 13.0 GB at 262,144 tokens instead of about 22.8 GB for every request.
- Serve GLM-5.3-Flash in coordinator-connected mode as catalog model `glm-5.3-flash`, downloaded through the normal model-revision path and loaded by the same managed native load, embedded MTP, paged KV, prefix cache and wired residency as the local opt-in. The coordinator catalog entry, the revision receipt and the loaded bytes must agree on one aggregate, and the reviewed shipped template stays mandatory. The enforced context is 262,144 tokens; a larger catalog `max_context_length` refuses the load. GLM loads only on Apple M5 Max or M5 Ultra with at least 256 GB of unified memory: the provider reports the new runtime capability `glm5_next_v1` only there, the build requires `apple_m5`, `mlx_nax` and `glm5_next_v1`, and other Macs report their chip and memory in the refusal. GLM requests reserve target KV (33,836 bytes per token; 8.87 GB for a full request), native step scratch and embedded-MTP state per actual reserved token, alongside the fixed recurrent and MTP charges, and the running-row cap is the largest the engine's step-scratch activation check admits; the slot reports that combined rate as `kv_bytes_per_token`, must hold one full-length request to publish, and refuses a request larger than its whole pool as capacity instead of queueing it.
- Retain GLM native owners and wired-memory policy entries after backend residency start/end faults. Refuse publication after a failed start and wait for pending ticket work before reporting clean retirement; unsupported platforms skip ticket creation before backend work. Keep the bridge engine, KV claim and activity guards through residency settlement so an end fault cannot erase the retained-memory charge.
- Reject malformed GLM tool suffixes instead of exposing parser fallback text, and report unproven compatibility shutdown through a fixed diagnostic while retaining resources.
- Add provider-hosted GLM aligned-read, descriptor-cache-policy and tiny-artifact loader regressions. They require the matching immutable SDK loader/reader implementation; native cases remain subject to exact-composition qualification.
- Build single-Mac GLM-5.3-Flash on the single-Mac native stack (`Layr-Labs/mlx` #37, `mlx-swift` #58 and `mlx-c` #16, merged from `work/glm53-flash-release`). It carries the quantized tile-bound, allocation-cap, page-backed footprint and 512-thread launch fixes the GLM path needs, without the two-Mac JACCL, sealed all-sum and collective startup-wait changes, so this release does not depend on the cluster pull requests. Compared with v0.9.22 the MLX quantized and NAX Metal kernel sources change; see Upgrade and rollout notes.
- Report why a complete-checkpoint SSD prefix store (the only GLM prefix cache) was not built instead of silently serving uncached: the provider logs one public line naming the model and a typed reason such as `key_unavailable` with the Keychain/Secure Enclave status (an ad hoc signed build has no keychain access group), and local `/metrics` adds `detail="<reason>"` to the `error` `prefix_cache_status`; the heartbeat reason stays `cache_init_failed`. DEBUG builds only can take a persistent cache key from an operator-created 32-byte, mode-0600 file named by `DARKBLOOM_DEBUG_CACHE_KEY_FILE` for qualification; release builds do not contain that path.
- Accept OpenRouter's GLM reasoning controls: `reasoning.enabled: true`, `reasoning.exclude: false`, `include_reasoning: true`, `enable_thinking: true` and `chat_template_kwargs` `enable_thinking`/`thinking: true` are no-ops that leave the prompt unchanged, and a positive `reasoning.max_tokens` without an effort selects `low` (up to 1,024), `high` (up to 8,192) or `max`. GLM thinking can be turned off with `reasoning.enabled: false`, `enable_thinking: false`, `chat_template_kwargs` `enable_thinking`/`thinking: false` or effort `none`/`off`: the prompt ends with an empty `<think></think>` block, as the template writes for an assistant turn without reasoning, and the answer is content only. Thinking-off combined with a thinking-on switch, an effort level or a reasoning budget gets HTTP 400. Hiding generated reasoning (`reasoning.exclude: true`, `include_reasoning: false`) still gets HTTP 400 with the fixed local message "GLM-5.3-Flash returns the reasoning it generates; reasoning.exclude true and include_reasoning false are unsupported. To turn thinking off, send reasoning.enabled false, enable_thinking false or reasoning_effort none." and code `unsupported_value`.
- Hash model weights with uncached (`F_NOCACHE`), page-aligned reads before and after a load, so integrity hashing no longer pulls a second copy of the weights through the file cache. On a 256 GB M5 Ultra the cached pre- and post-load hashes of GLM-5.3-Flash's 181.7 GB pushed about 150 GB of the just-loaded weights into the memory compressor (memory pressure warning) and stalled the first request. Digests are unchanged.
- Pin the SDK with GLM-5.3-Flash's bitwise kernel speedups for one Mac (mlx-swift-lm #314): KDA prefill recurrence and long-step convolution, MoE NAX tile plan, shared experts inside the routed prefill launches where MLX itself would not split K (65 rows and more), faster MoE gathers and decode router, one-launch hyper-connection sites, DSA decode selection and prefill projections. On one M5 Ultra the greedy output is byte-identical to the previous pin (provider endpoint 14/14, SDK fixed-depth MTP 30/30 token sequences) while prefill is 12–13 % and decode 16–18 % faster. The MTP history work is now charged per prefill chunk, so each GLM MTP request reserves 4.89 GB fixed instead of 11.31 GB.
- Bring three bit-identical GLM-5.3-Flash speedups that previously reached only the deprecated contiguous forward to the paged path that serves it (mlx-swift-lm #314): decode and verification steps reuse a shared all-true validity mask and build their token embeddings in one launch; prefill attention projections on Neural-Accelerator GPUs run a native GEMM kernel that matches MLX's bit for bit; and each sparse-attention layer stages its KV rows in one launch. Output is bit-identical to the previous pin. Paged decode and MTP verification keep the absorbed attention: the split-K sparse decode attention stays off on the paged path because its output is not bit-identical to the previous pin. The prefill projections give bit-identical logits on a 15,901-position perplexity panel.
- A request refused because the Mac's serving concurrency is full, or (GLM) because the slot is full or the request can never fit it, now gets HTTP 503 with the fixed capacity message before any response headers, for streaming and non-streaming requests, instead of a 200 stream ending in a `server_error` "Response generation failed" frame. Coordinator-connected requests still receive a retryable `capacity`/503 `token_budget_exhausted` error, now sent before the stream with the usual capacity-rejection fields.
- Keep running GLM requests alive when memory is nearly full: a step whose scratch reservation is refused is now deferred instead of failing every row of the step; the requests admitted in that step wait for capacity and new admissions pause until a running request leaves (mlx-swift-lm #314). On one M5 Ultra with the SSD prefix store, three ~60K-token requests previously all failed when the second finished prefill; now the running ones continue and the third waits.

### GLM-5.3-Flash video input

- Serve GLM-5.3-Flash `video_url` parts (inline `data:video/mp4` or `data:video/quicktime`) instead of refusing them with 400. The processor reads every frame of the constant-frame-rate track but converts and keeps only the 2 FPS official sample (RGB8, within its 512 MiB decoded-frame cap), and places each sampled frame pair as an image-token span with its timestamp; video rows decode target-only and never reuse cached prefixes, like images. The media reservation adds each video's token ceiling and, once, the processor's decoded-frame cap (videos decode one at a time). Variable-frame-rate clips, clips whose sampled frames exceed the decoded-frame cap and clips whose visual tokens exceed the shared 28,532-token prepared-pixel cap are refused with 400.

### MiMo tool-schema ingress parity

- Preserve original MiMo Chat function-tool schemas across provider/local prompt rendering, serving, recount and benchmark preparation, including typeless enums and Boolean properties.
- Keep existing hosted-tool fallback, malformed-declaration refusal, reserved-schema metadata checks and other model families' normalization.
- Add public scripted-generation regressions; full-model and live platform qualification remain separate.

### GPT-OSS bf16 activations and KV

- A bf16 GPT-OSS checkpoint such as `gpt-oss-20b` now keeps bf16 activations
  and native K/V on every layer. The expert SwiGLU clamp used float32 bounds,
  which promoted every layer after the first to float32; its scalar bounds now
  take the activation dtype. Float32 models are unchanged.
- `gpt-oss-20b` native full-attention K/V falls from 49,152 to 24,576 bytes per
  token. A slot grant holds about twice as many GPT-OSS tokens, and the
  heartbeat `kv_bytes_per_token` halves. Admission, paged storage and
  checkpoint identity already use the observed native K/V types.
- Measured cold TTFT falls 21-26% on an M5 Ultra (512-8,192-token prompts)
  and 14-18% on an M3 Ultra (2,048-32,768 tokens). Aggregate decode at batch 8
  rises from 153 to 519 tokens/s on the M5 Ultra and from 275 to 314 on the
  M3 Ultra.
- Output is not bit-identical to the float32 path. On 6 teacher-forced samples
  of 256 tokens, mean token NLL moved from 3.8146 to 3.8123 and top-1
  agreement with the float32 path was 93.3%.
- GPT-OSS SSD complete checkpoints written with float32 layer types use a
  different checkpoint namespace and are not restored. Matching prompts
  prefill cold until new checkpoints are written; the old files expire.
- The 3.5 GiB `gpt-oss-20b` activation floor is unchanged. It was measured on
  the float32 path.

### Wider mixed-step prefill for Gemma 4

- Gemma 4 prefills prompts in 2,048-token chunks with a 4,096-token step budget, including while other requests are decoding, instead of 512-token chunks beside decode. Busy engines reach the first token sooner and decode each stream faster; solo prefill chunking, KV capacity, paged ring sizes, load quotations and activation floors are unchanged. On contiguous KV (Gemma 4 artifacts other than the catalog's paged `gemma-4-26b-qat-4bit`, or with paging disabled), a solo prompt whose 2,048-token chunk cannot reserve KV now waits or is preempted instead of retrying with 512-token chunks, as the former 2,048-token stripe did.
- Gemma 4 image and video requests keep 512-token chunks, so their attention memory is unchanged.
- A decode token that shares a step with a long prompt now waits for a 2,048-token chunk instead of a 512-token one: typical inter-token gaps shrink, the slowest grow.
- GPT-OSS and dense Qwen3.5/3.8 also reached the first token sooner with the wide geometry, but at eight 32k-token prompts it raised their activation peaks further above their memory floors, so they keep the 512-token chunk and 2,048-token step by default. Nemotron 3.5, Bonsai, MoE Qwen, Qwen3-VL, Qwen4, MiMo and other families keep them too.
- Set `DARKBLOOM_CBV2_PREFILL_CHUNK=512` and `DARKBLOOM_CBV2_STEP_TOKENS=2048` to restore the previous Gemma 4 geometry, or `2048` and `4096` to opt another family in; `darkbloom start` forwards both to the background provider. Either override disqualifies reviewed serving and deadline profiles, like other `DARKBLOOM_CBV2_*` settings.

### Qwen3.8 forced tool calls

- The embedded-MTP Qwen3.8-27B build now advertises `tool_choice` `required`
  and named-function support, like the original build it replaced, and forced
  calls accept the catalog's default `qwen3_5` parser instead of failing with
  an invalid request.

### Qwen3.8 unsupported reasoning effort is a client error

Qwen3.8-27B requests with thinking enabled and an effort its template does not
accept, such as `high` or `minimal`, now fail before rendering with the typed
HTTP 400 that Flash-Next already returns. Text requests previously surfaced as
a provider 500 `template_render` failure; media requests hit the same raise
inside vision preparation and were reported as a retryable 503
`capacity_busy`. Typed request errors from media preparation now keep their
own status.

### Qwen and Bonsai histories without a user query are a client error

Qwen 3.5, 3.6 and 3.8 and Ternary Bonsai 2 requests whose history has no user
turn beyond `<tool_response>` wrappers (for example only a system message, or
system plus assistant) now fail before rendering with a typed HTTP 400. They
previously reached the template's "No user query found in messages." raise
and surfaced as a provider 500 `template_render` failure.

### Tool calls stream while they are generated

Chat streams now send `tool_choice: "auto"` calls from Gemma 4, Qwen 3.5, 3.6
and 3.8, GPT-OSS and framed-JSON models as OpenAI `tool_calls` fragments while
the model generates them. The call's `id`, `type` and function name arrive as
soon as the name is generated, followed by argument fragments. A response that
started with a tool call previously had no content until the whole call and the
end of generation were produced, so its time to first token included the
entire call. Each call is still validated against its declared tool and schema
when it completes. Required and named tool choices keep validating before
anything is shown.

Long tool calls in the Gemma, GPT-OSS and framed-JSON formats no longer cost
provider CPU time that grows with the square of their length: parsing a 64 KB
Gemma file write took about 20 s of CPU and now takes about 0.1 s.

Qwen3-VL Instruct, whose generation prompt carries no think marker, now
streams its answer instead of buffering it until the end.
`DARKBLOOM_TTFT_STREAM_TOOL_CALLS=0` and `DARKBLOOM_TTFT_THINK_CONTENT_SEED=0`
restore the previous behaviors.

### Faster prompt preparation and admission

- Prompt preparation reuses the token IDs of chat-template pieces (the text
  between special tokens) already seen in the same prefix-cache scope, so a
  follow-up turn of a long conversation no longer re-tokenizes its history.
  Token IDs equal the previous path's; a load-time self-check and sampled
  background comparisons disable reuse on any mismatch, including a prompt
  the previous path would have rejected. On an M3 Ultra a
  27–38K-token follow-up turn now prepares in 5–8 ms instead of 102–264 ms,
  and new long prompts prepare 2.3–3.4× faster, encoded on several cores.
  `DARKBLOOM_TTFT_PROMPT_CACHE=0` restores the previous path.
- Gemma 4 and GPT-OSS chat templates rescanned the whole history for every
  message, so render time grew with the square of the history length: 0.72 s
  for 1,603 Gemma messages on an M3 Ultra, on every request. Cached
  prompts now render through equivalent linear-time forms of those loops
  (26 ms for the same history), checked against the served template at load
  and in the background comparisons. A 610-message, 44–46K-token agent loop
  now prepares a follow-up turn in 15–21 ms instead of 213–346 ms. In an
  end-to-end tool loop of about 400 messages and 18–22K tokens, every request
  reached its first token 45–152 ms sooner on Gemma 4 and GPT-OSS.
  `DARKBLOOM_TTFT_TEMPLATE_LOOPS=0` keeps the served template.
- The Jinja null sanitizer returns plain string, number and Boolean leaves
  without reflection: 5.4 ms instead of 12.5 ms for a 603-message history.
- For requests without tools or legacy function calls, the decrypted request
  body is parsed once for the chat request and its extension fields instead
  of five times.
- A request waiting for a cold model load (other than native MiMo) no longer
  holds the coordinator work queue: resident models' requests, cancels and
  attestation challenges proceed while it loads, and a cancel for it still
  applies when its admission returns. A request for another model that is not
  resident still waits for that load, so its capacity check sees the memory
  the load takes. A request for the model being loaded that fails that check
  while the load runs is checked again once the load returns, as before.
  `DARKBLOOM_TTFT_COLD_LOAD_RELEASE=0` restores the serial queue.

### Startup shape warmup

- After a new install or a macOS or MLX kernel update, the first long prompt for each model paid seconds of on-demand Metal kernel compiles: an 8K-token first request took 4.4 s instead of 2.9-3.0 s (Gemma 4 QAT) and 4.1-4.2 s instead of 3.4 s (GPT-OSS) on an M3 Ultra, and 3.2 s instead of 1.1 s and 5.3 s instead of 1.6 s on a shared M5 Ultra. Startup preload now warms the kernels that long prompts, the served batch width and MTP verify use, after each model loads and passes any self-test, before the provider registers or the local listener opens. A short probe skips the warmup when the compiled-kernel cache is already warm (about 0.2-0.3 s per model); on a cold cache the warmup takes 5.4-7.4 s per model before registration or the listener. If the served batch width grows later (power or thermal posture recovers, or more KV memory frees up), the next idle moment warms the wider width too. The warmup trains no rates, yields to any request, stays within 20 seconds per model and logs its outcome. This release changes the MLX kernels, so the first start after updating takes the cold-cache path. Set `DARKBLOOM_TTFT_SHAPE_WARMUP=0` to disable it, or `always` to skip the probe.

### Fewer GPU stalls while serving

- The proactive MLX buffer-cache sweep no longer flushes between busy engines' steps while admission headroom is healthy. It waits for five seconds of whole-Mac idleness and then flushes without reporting device activity, so deadline quiescence and idle calibration survive it; a request that arrives during that flush is admitted after it instead of starting on a pool being emptied. While engines serve it flushes only when the reusable pool crowds out admission headroom, and a refused engine-owned KV charge or native MiMo media reservation now signals the same shortfall-gated reclaim as request reservations. Load gates drop that pool and resample before evicting a resident model. `DARKBLOOM_TTFT_IDLE_CACHE_SWEEP=0` restores the old sweep; refusals keep signalling while segment retention is on.
- Paged KV pools keep up to an eighth of their slot grant (at most 2 GiB) of free segments across requests and reinstall them for the next admission instead of allocating, zero-filling and fencing new 64 MiB segments. New segments wrap zero-fill-on-demand host pages, so admission no longer drains queued GPU work under the process-wide MLX eval lock. Retained segments are uncommitted (no grant, floor or ledger charge), are dropped on a refused admission or on process memory pressure (any refused charge, a pressure sweep or a macOS memory-pressure event) and return to the allocator after 30 s of engine idleness. The provider, standalone and managed Nemotron Super load gates release them before evicting a resident model or refusing, and startup preload releases them before skipping a model. Cold loads count them as reclaimable only until that release: segments a busy engine has not dropped by the end of the release's wait never justify evicting an idle model, and pre-accept releases them and resamples before admitting a request on them. `DARKBLOOM_TTFT_SEGMENT_RETENTION=0` restores release-time trimming and device-filled segments; `DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS=0` keeps retention with device fills.
- `darkbloom start` forwards all three rollbacks to the background provider, so they also reach launchd-managed providers.

### Qwen MTP decode without seed steps

- Qwen 3.5, 3.6 and 3.8 requests with the inline MTP head decode as ordinary chained steps while more than one request is decoding, because the head speculates for one decode row only. These steps previously ran unchained, each with a vocabulary-wide policy top-two reduction and an extra host readback. The head's history is still fed from every committed position, so speculation resumes without a seed step when one request remains.
- The final prompt position seeds the first speculative round, so speculation starts right after the first token instead of after one extra target-only step.
- Rollback: `DARKBLOOM_TTFT_QWEN_MTP_CHAINED=0` restores the seed steps and `DARKBLOOM_TTFT_QWEN_MTP_CARRY=0` restores the post-first-token seed step, in processes that receive them (LaunchAgents do not forward them).
- Add opt-in `benchmark --runtime-generation --runtime-concurrency <sizes> [--runtime-stagger]`: one production slot per batch size, with per-token arrival times, chained steps and MTP counters as JSON, plus model, prompt, precision and assistant provenance. Malformed size lists, and staggered runs whose `--max-tokens` is below 3×B, are refused before the model loads; a slot narrower than its batch, a `length` terminal before the row's quota, a `stop` without a configured stop token or an early stop in stagger mode exits with status 2 instead of passing as a measurement.

### Faster Qwen Gated DeltaNet prompt prefill

- Run Gated DeltaNet prompt chunks of 16 or more tokens for Qwen3.5, Qwen3.6, Qwen3.8 and Bonsai 2 models on kernels that compute four value rows per SIMD group. On M5 Ultra the per-layer recurrence is 1.45-1.70x faster (Qwen3.5-9B geometry, 4,096-token chunk: 3.160 to 1.930 ms), which is estimated to save 3-4% of Qwen3.5-9B cold time to first token at 8K-32K prompt tokens. Decode, MTP verification, masked updates and shorter chunks keep the existing kernel.
- A new kernel runs only where it reproduces the existing kernel bit for bit, so outputs and recurrent checkpoints do not change: the first prompt chunk of each model geometry checks this on the GPU and keeps the existing kernel where no candidate matches. On M3 Ultra, Qwen3.5-9B cold prefill takes 1.1-1.3% less time at 2K-32K prompt tokens; speed on other M1-M4 GPUs is unmeasured. `DARKBLOOM_TTFT_GDN_BLOCKED=0` restores the existing kernel. `darkbloom start` forwards it to the background provider, so the rollback also reaches launchd-managed providers.

### Fused causal prompt attention

- Attend a full-attention prompt chunk with one fused causal attention call instead of 128-query blocks when MLX serves its head geometry with a fused kernel: head_dim 64, 72, 80, 96 or 128 on every Apple GPU, and head_dim 256 on M5 (NAX) chips for chunks of at least 1024 tokens. That includes the full-attention layers of GPT-OSS and Nemotron 3.5 Lightning on every chip and the head_dim 256 full-attention layers of Qwen-family models in M5 solo prefill stripes; sliding-window, softcapped, vision-span, live packed paged KV and Gemma 4 layers are unchanged.
- On M3 Ultra, GPT-OSS 20B cold time to first token drops from 19.5 s to 17.4 s at 32K prompt tokens and from 3.41 s to 3.30 s at 8K. On M5 Ultra, Qwen3.5-9B peak memory at 32K prompt tokens drops from 13.86 GB to 12.03 GB because its head_dim 256 layers no longer materialize attention scores.
- GPT-OSS teacher-forced scores are bit-identical; Qwen output on M5 can differ within bf16 rounding; Nemotron 3.5 Lightning and the other qualifying models were not measured. `DARKBLOOM_TTFT_FUSED_CAUSAL_PREFILL=0` restores the blocked path in a foreground process; the provider LaunchAgent does not receive it.

### Deadline admission estimators

- Charge decode in first-token deadline projections once per batch step, priced from the step shape the decode rate was measured at (rows, confirmed tokens and draft width per step), instead of summing every running row's tokens against a per-request rate. Each measured step's duration is smoothed together with its shape, so requests measured at different batch widths never pair one width's rate with another's rows, and the rows of the step that produced the first token, which the decode rate does not time, are left out. An MTP round is priced by the tokens it was measured confirming rather than its full draft width. Rows the live MTP planner cannot speculate (beyond its batch gate, or with no depth left inside the automatic verification envelope) are charged their one target token instead of the full draft width, no row is charged more depth than that envelope allows, and a full-slot MTP stretch with no live depth is projected in one jump like plain decode. A request carrying a reviewed deadline calibration keeps the per-row charge its error envelope was measured against.
- Stop one slow "isolated" prefill sample from locking an ordinary engine out of deadline admission until restart. The aggregate prefill rate is never priced below one eighth of the startup calibration's idle rate, and isolated evidence that expired while the whole Mac was idle at nominal posture is priced at no less than that rate. Evidence older than 30 minutes on an idle Mac is treated as absent, with or without a calibrated rate, so a calibration slowed by another process cannot lock admission either. The Mac counts as idle only when no other request on any resident model and no model load, encoder preparation or cache transfer is in progress. A fresh measurement for the request's prompt size still applies below that floor, so a short calibration never vouches for a long prompt. Published rates are unchanged.
- Keep measurement age and expiry tied to the newest observation when older completed work arrives later, and stop a late older cold sample from restarting the combined prefill estimate.
- `DARKBLOOM_TTFT_ADMISSION_FIXES=0` restores the previous estimators. `darkbloom start` forwards it to the background provider, so the rollback also reaches launchd-managed providers.

### SSD restore no longer waits behind another request's prefill

- Restoring a complete prefix checkpoint from SSD no longer blocks on MLX's
  process-wide eval lock while the engine runs another request's prefill
  chunk. On an M5 Max with Qwen 3.8 27B, staging a 0.96 GB checkpoint during a
  concurrent prefill dropped from 2.6–3.8 s to about 0.35 s.
- Added the opt-in `ModelCheckpointRestoreContentionLiveTests` real-model
  regression, which requires SSD restore to reach its demanded boundary, never
  to produce its first token later than cold prefill, idle or contended, and to
  stage as fast contended as idle.

### Deeper SSD checkpoint restores on large-memory Macs

- On Macs with at least 48 GiB, complete-checkpoint SSD restores now default
  to a 7 GiB / 15 s staging cap instead of 1 GiB / 1 s. With Qwen 3.8 and MTP
  the deepest restorable prompt prefix rises from 8,192 tokens to about
  94,000. On an M5 Max 128 GB a 20k-token fork's first token dropped from
  about 17 s to 6 s (27 s cold). Explicit
  `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` / `_MS` settings still win in
  processes that receive them (LaunchAgents do not forward them), attention
  block caches keep their defaults, and the daily SSD write cap is unchanged.

### Local Responses continuation and reasoning

- Continue local Responses requests with `previous_response_id`, preserving input, reasoning and correlated tool history. Reject non-null invalid ID types and unavailable IDs with HTTP 400 before model acquisition; null remains absence.
- Bound continuation history with an application-local LRU. Response retrieval uses a separate in-memory object store, so a retrievable response can have expired continuation history; neither store survives application restart. `store: false` suppresses both new saves.
- Select omitted local reasoning parsers by model type while preserving explicit overrides. Keep unfinished prompt-side thinking in reasoning fields for collected Chat and Responses, retrieval and continued history, with the paired SDK parser repair; native parsed channels and token usage remain authoritative.

### Provider start and terminal hangups

- Stop the interactive model picker (`darkbloom start`, `darkbloom switch`) when its terminal goes away. It previously kept reading a closed input and used a full processor core until the process was killed; it now cancels as Esc does, restores the terminal mode and leaves the provider unchanged.
- Drain a provider started by hand (`start --local`, or `start --foreground` in a terminal) when its terminal window closes, the same cooperative stop as Ctrl-C and `SIGTERM`, instead of ending the process at once. The launchd-run provider and a start made with `SIGHUP` ignored (for example under `nohup`) behave as before.

### Picker serving-set reserve

- Use the complete ordinary model selection's activation reserve in the catalog picker, so measured-only choices are not rejected using the unknown-model floor. Recheck existing choices when adding a model raises that reserve. Preserve the conservative Autopilot enrollment check and runtime memory safeguards.

### Fan helper startup discovery

- Retry an unusable startup fan or GPU sensor inventory every 30 seconds while the helper is enabled and awake. Restore previous ownership before accepting recovered hardware and require a fresh provider lease before engaging fans; transiently invalid startup sensor readings no longer leave the helper permanently unsupported. The fix is in the root fan helper: after updating, run `sudo darkbloom fan enable` so the installed helper matches the new app bundle.

### Interrupted watchdog launch recovery

- Recover a candidate's launch receipt when the watchdog exits after starting it but before recording success. A running candidate that never produces a heartbeat then reaches the existing startup timeout; missing launch evidence does not count as a failed start.
- Preserve unproven launch intent across health observations before restart. Require comparable saved and current launch evidence so an old serving process cannot acquire a false failed-start timeout when baseline evidence is missing or partial.

### Watchdog restart acknowledgement

- When a provider job disappears between the watchdog's launchd check and kickstart, report that no restart occurred and restore the previous crash-loop backend guard. Keep stopped or uninstalled jobs unloaded instead of recording a restart that launchd refused.

### Installer release file modes

- Extract the release bundle under umask 022 with `/usr/bin/tar`, so a restrictive caller umask no longer leaves installed app files owner-only. Private state created elsewhere by the installer is unchanged. New installs get it once the coordinator serves an installer that includes it; `darkbloom update` and the self-updater extract separately and are unchanged.

### Staging build environment

- Add `staging` as a third provider build environment beside production and dev. It has its own install identity (`darkbloom-staging`, Secure Enclave helper `darkbloom-enclave-staging`, app `Darkbloom Staging.app`, install dir `~/.darkbloom-staging`, config dir `~/.config/darkbloom-staging`, local port `8002`, LaunchAgent `io.darkbloom.provider.staging`, keychain prefix `io.darkbloom.staging`, encrypted-cache namespace `darkbloom-staging`) and the staging coordinator `wss://api.staging.darkbloom.dev/ws/provider`, so a staging provider runs beside production and dev on the same Mac. It shares the production model CDN like dev, and the signing identifier, keychain access group, MDM identifiers and fan helper stay shared across all three environments.
- Select the staging identity from a `-staging.N` version in the installer and the release tooling. Build it with `DARKBLOOM_RELEASE_ENVIRONMENT=staging` (`DARKBLOOM_ENV_STAGING`).
- A staging run uses only `STAGING_*` secrets. A tag never resolves to staging; master pushes publish staging only when `STAGING_ENABLED` is set (next entry).

### Master push publishes dev and staging provider releases

- A push to `master` now publishes a staging provider release in parallel with the dev release (DBLM-771: staging tracks main), gated by the `STAGING_ENABLED` repository variable. Staging is a normal Developer-ID dev-family release signed with the same certificate as dev and prod, versioned `X.Y.Z-staging.N` by the workflow run number. The gate defaults off (variable unset), so a master push builds and publishes dev only.
- Refactor the provider release pipeline into a thin caller (`.github/workflows/release-swift.yml`) and a reusable workflow (`.github/workflows/release-provider.yml`, `on: workflow_call`) that encapsulates the whole resolve, build, qualification, signing, R2 staging and publication chain for one environment. The caller routes each trigger to its lanes: a master push runs the `dev` and `staging` lanes in parallel, a `vX.Y.Z` tag runs the `prod` lane, and a dispatch runs the chosen environment. A plain matrix cannot carry each lane's artifact id and digest across the dependent jobs, so each lane is a separate call of the reusable workflow.
- The dev and prod paths are preserved exactly: the same signing, notarization, serialization groups (`release-dev` for dev, a per-run group for prod), version stamping and publication idempotency. prod remains tag-gated — `scripts/resolve-provider-release.sh` refuses prod on any non-tag trigger — so a master push can never reach the production signing identity. Accepted cost: with staging enabled, one master push runs two full build, sign, notarize and publish lanes (dev and staging are different binaries, identity is compile-time). Staging publication is not operational yet: without the `STAGING_*` secrets the lane fails when it resolves them, after build and qualification, and the publication step accepts only `dev` and `prod`. Keep `STAGING_ENABLED` unset until both are in place.

### Experimental dev-branch provider lane

- Add `.github/workflows/release-dev-branch.yml`, a dispatch-only lane that builds a provider from any branch or commit and publishes it to the dev coordinator as a self-signed (ad-hoc) release, without merging to master. It is dev-only: no tag path, no production environment, no production signing identity, and no production secret. It stamps the version `X.Y.Z-dev.branch.<run>` so it stays distinct from the master dev lane.
- Relax the installer signature check for pre-release versions only: for a version carrying `-dev.` or `-staging.`, `scripts/install.sh` accepts an ad-hoc or otherwise non-Apple-anchored signature while keeping the bundle identifier pinned and every other check in force. Production versions keep the full Apple-team requirement unchanged. The dev coordinator serves the relaxed installer only after the platform-served copy is re-snapshotted.
- The lane has not completed a run. The shared build step accepts only the dispatching `master` commit, and the installer still requires an Apple-signed fan helper, so it cannot yet deliver a branch build.

### Model publication

- Publish an already uploaded revision through the Register Model workflow without R2 credentials, preserving model metadata and prices.
- Document model-bucket access checks and the Bonsai 9B publication incident.

### Fixed-input scheduler-prefill benchmarks

- Add opt-in `benchmark --scheduler-prefill --prefill-fixed-prompt` to repeat seed offset zero for warmup and measured iterations. Default measured prompts retain their rotation; other benchmark modes reject the flag.
- Record prompt mode, warmup offset and per-sample offsets in backward-compatible optional report fields. Fresh engines, disabled prefix caching and the existing prefill stripe remain unchanged.
- Initialize the serving allocator limits before scheduler-prefill model loading and log the applied cache limit, matching the throughput sweep and serving paths.

### SSD test working-volume selection

- Honor the selected test working volume in SSD-prefix and bridge write fixtures,
  and report directory setup errors directly. Production cache safeguards remain
  unchanged.

### Threat review reliability

- Distinguish completed scans requiring human review from failed or incomplete
  scans. Preserve change context across source batches and reconcile Sol's local
  questions before its final decision, within existing spending limits.
- Add content-free failure diagnostics with validation codes, JSON positions,
  model/batch correlation and Bedrock request metadata. Raw responses, prompts,
  source text and credentials are excluded from diagnostic artifacts.
- Keep unresolved cross-file questions for human review and restrict each
  model's integration citations to its reviewed source. Preserve diagnostic
  progress across interruptions without allowing logging failures to hide reports.

### Threat review failure recovery

- New reviews use the current trusted scanner with the PR base threat model,
  preventing old PR bases from retaining obsolete review code.
- Request native Bedrock JSON output and nonempty batch analysis while retaining
  strict local validation and the existing model, spend and merge policies.
- Recover bounded report/cache write conflicts without repeating paid requests;
  distinguish state, GitHub and OpenRouter failures in content-free diagnostics.
- Give final integration reviewers bounded exact source evidence from their own
  reviewed scope, retaining explicit omissions and human-review decisions.
- Preserve Bedrock cache-read/write input accounting and enforce finding-text
  and analysis limits on raw characters, including whitespace padding.
- Stop further model calls after backup cost-accounting failures even if the
  primary provider recovers, retaining validated findings.

### Threat-review recovery and evidence retention

- Repair one otherwise valid response with empty/oversized analysis or incorrect
  primary acknowledgment per scan, within existing limits. Distinguish replayed
  source IDs and constrain integration acknowledgments; retain earlier findings
  and uncertainty. A second failure remains incomplete.
- Extend bounded retries for explicit state-branch conflicts without repeating
  paid calls. Persistent conflicts still stop the review.
- Retain validated advice and original diagnostics when native usage accounting
  or final-result delivery fails. Stop further spending on unknown accounting;
  reject final results from another workflow run or attempt.
- Record repair status and original request metadata in safe diagnostics and PR
  feedback. Distinguish a closed/merged PR from a technical review failure.

### Automatic threat-review completion and human handoff

CI sizes native review allowances from source batches, selected independent depth
and cross-file integration rounds, retaining one shared response repair and an
emergency ceiling. Generous native defaults allow up to 500 calls and 16,384
output tokens per call with ten minutes per native response. Maintainers can
lower the call and output limits through Actions variables. A longer bounded
scan deadline leaves time to save findings
and publish a human-review handoff when the scan cannot complete.

Normal reviews send critical source directly to Sol instead of repeating it with
Opus first. All source still receives Sonnet review and cross-file integration;
clean tests/docs avoid filename-only depth, and integration findings target their
cited batches. Global uncertainty requires human review without a blanket rescan.
Production attestation filenames are not mistaken for Swift test suffixes;
critical source outside explicit support trees takes precedence over filename hints.

Paid manual dispatches and GitHub job reruns are disabled. Incomplete reviews
explicitly require a human and cannot grant merge clearance. Advisory mode and
existing OpenRouter spending limits remain unchanged.

## v0.9.22

Published 2026-10-15 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.22)).

### Native Bonsai 9B preparation

Preserve native tool/reasoning framing and artifact sampling defaults for the Bonsai 9B candidate. Honor its image minimum within the existing serving budget. Honor explicit tanh/exact GELU declarations in native Qwen3.5 vision blocks, preserving the existing fallback for missing or unknown declarations. Select paged attention and encrypted SSD prefix caching by default for its exact identity, retaining operator opt-outs and runtime security/capability checks. Reject requests beyond the checkpoint's native context limit before inference.

Request MTP by default in automatic mode for the exact Prism/Eigen 9B identities and architecture. Resolve a validated catalog assistant asynchronously, with an explicit local path taking precedence, including the inspected affine 4-bit/group-64 head while retaining F16 rollback compatibility. Preserve the checkpoint's original base-weight precision, default to exact acceptance, and cap draft depth at two. Preserve drafter-required rectangular verification when runtime eligibility permits, with the existing target-only fallback. Plain inference remains available without the optional sidecar. Actual-artifact qualification and publication remain separate gates.

Return a structured HTTP 503 invalid_request_error when local POST admission has closed for a graceful drain. Preserve CORS headers, health checks, preflight requests, and ownership of already admitted responses.

Recognize the exact Prism and Eigen Labs 9B identifiers through the same request, cache and local MTP policies; artifact publication and coordinator activation remain separate.

### M5 paged serving concurrency

- Serve up to 8 concurrent requests per model by default on M5 Pro, M5 Max and M5 Ultra for models that the default `auto` backend selects for paged KV, when `engine_v2_max_concurrent` is absent from `provider.toml`. Other chips, contiguous models, models paged only by an explicit backend or live KV quantization setting, explicit global or per-model concurrency settings (including a `4` written by older releases) and reviewed profiles are unchanged; the coordinator's per-model quality cap still bounds admission.
- Fall back from that width to the configured width under Low Power Mode or thermal pressure, as reviewed profiles already do. `darkbloom status` and `doctor` describe the M5 default.

## v0.9.21

Published 2026-10-14 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.21)).

### Fixed

- Keep one-token startup health-check timings out of serving throughput estimates, and bootstrap supported loaded models, including ordinary dense and MoE Qwens, with bounded, preemptible measurements so slow first-use samples do not leave warm providers waiting for their first jobs.

### Dev provider builds have their own identity

- A dev build is now `darkbloom-dev` in `Darkbloom Dev.app`, installed in `~/.darkbloom-dev` with its configuration in `~/.config/darkbloom-dev`. It uses the LaunchAgent labels `io.darkbloom.provider.dev` and `io.darkbloom.watchdog.dev`, the default direct-mode port `8001`, its own encrypted KV cache directory (`darkbloom-dev/kv3`, also under a configured cache directory), its own log subsystems and its own keychain items. Downloaded model weights stay shared, but each install selects its own active revision. A dev provider and a production provider can run on the same Mac.
- The installer selects the dev identity when the release version contains `-dev.`. Production names, paths, ports, labels and keychain items are unchanged.
- An earlier dev install in `~/.darkbloom` cannot update to a dev build with the new names. Install the dev provider again with the dev `install.sh`.
- With both installs on one Mac: each install accepts only its own coordinator's MDM profile and names the other's; crash and jetsam reports match the exact process name; the fan helper keeps fans under control while either provider holds a lease, and `fan disable` / `fan uninstall` warn that they affect both; `doctor` warns when the other provider is running. The shared APNs app identity and `DARKBLOOM_*` shell overrides are documented limitations.
- Production change: provider OOM detection now matches only the exact process name `darkbloom`. Jetsam and memory-crash reports for `darkbloom-enclave`, the fan helper or any other process whose name contains `darkbloom` no longer count as provider OOM events. A crash report matches when its `app_name`, `name` or `procName` equals the process name.
- The fan helper is now version 2. It keeps one lease for each provider session. `fan status` and `doctor` report an older installed helper with the command that updates it (`sudo <cli> fan enable`), and `fan enable` refuses to replace a newer running helper with an older one.

### Automatic dev provider releases

- A push to `master` that changes the provider or its release tooling now builds, signs, notarizes and publishes a dev provider release. Tags still publish production releases unchanged.
- Every dev build has the version `X.Y.Z-dev.<run number>`. `darkbloom --version` shows it, and dev providers update to each newer dev build. Dev runs never receive `PROD_*` secret values.

### Provider repository ownership

- Remove centralized coordinator/backend, admin, integration-harness and deployment implementation from this repository; retain the Swift provider, local native runtime and landing site. The console source snapshot and its existing build, lint, test and hosting configuration remain unchanged. New backend, console and admin development belongs in the sibling platform repository; release/model registration remains an external API operation. Source ownership changes do not change deployed endpoints or authorize deployment.

### Agent-readable website discovery

- Give the Darkbloom website a stable canonical identity, structured product and organization metadata, and a public sitemap.
- Add readable product, pricing, contact and integration guidance, including Markdown responses and recovery links for agents.
- Publish a source-reviewed consumer API description while preserving API authentication and the existing browser experience.

### Community headlines and story browsing

- Introduce the homepage with “AI, powered by your Macs.” and the live grid with “Many Macs. One network.” Highlight the trailblazers and people contributing to the network.
- Browse stories by dragging or scrolling horizontally over their media or text, with keyboard navigation and native vertical scrolling preserved.

## v0.9.20

Published 2026-10-12 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.20)).

- Raise the default SSD cache write budget from 750 GB to 4 TB (4,000 decimal GB)
  per rolling day. Saved limits and environment overrides continue to take precedence.

### Responsive provider App Attest handling

- Process App Attest challenges, received authorization updates and connection invalidation while inference or model work is suspended. Keep model-work ordering and existing proof, expiry, key-reuse and revocation checks.

### Provider build environment

- A dev provider release now defaults to the dev coordinator `wss://api.dev.darkbloom.dev/ws/provider`. It does not fall back to the production coordinator. Dev and prod builds read models from `https://models.darkbloom.ai`. Local builds, tests and production releases keep the production defaults. `provider.toml`, CLI flags and `DARKBLOOM_R2_CDN_URL` still override the defaults.
- The LaunchAgent now forwards `DARKBLOOM_R2_CDN_URL` to the daemon. `darkbloom doctor` prints the build environment, the coordinator and the model CDN. `runtime-smoke` prints a `build-environment-runtime-smoke` line first.

### Provider cache storage controls

- Add `darkbloom cache set --daily-write-gb ... --directory ...` and `cache status` for persistent write limits and optional external cache storage. Validate local APFS storage, require encryption for external volumes, pin the volume UUID and refuse unavailable or replaced disks without falling back. Keep encryption keys and the rolling-day write ledger on the Mac; switching disks does not reset usage. Changes apply after restart.

### App Attest diagnostic wording

- Identify the `darkbloom doctor` key-generation countdown as a local safeguard and explain that the coordinator may retry later.
- Report generation attempts and the last recorded invalid-key attestation failure without inferring that every new key failed its first attestation. Recovery and authorization policies are unchanged.

### Autopilot consent journal contention

- Let independent provider sessions record Autopilot consent concurrently instead of serializing the fleet behind the inventory write lock. Preserve per-session ownership, account-erasure fences, and exclusive protection for identity merges and reward settlement.
- Keep canonical-machine ownership lookups scoped to materialized ancestor IDs so PostgreSQL does not scan the complete provider-session history on each consent observation.

### Changelog fragments and release history

- Keep pending release notes in separate per-change Markdown files instead of having every pull request edit the shared changelog. Release preparation validates and renders the selected notes without modifying files automatically.
- Group historical notes under their first published source tags, split entries added in later versions, and retain candidate qualification and deployment limitations. Source inclusion is not proof of production activation.

### Member-only automatic security clearance

- Limit scan-only merge clearance to verified active Layr-Labs organization members. Non-members, bots and unavailable membership require independent formal human review. Use a separate read-only membership token and retain ordinary CI and current-revision checks.
- Surface fixed validation-failure reasons in incomplete review reports without exposing raw provider output.

### Native inference and quantized checkpoints

- Default live attention to native precision and independently request balanced encrypted-checkpoint storage for eligible native paged and contiguous engines. Preserve explicit live `balanced`, `k8v4` and `k8v8` settings; checkpoint compression does not force paging or reduce native serving-memory reservations.
- Add separate checkpoint configuration, environment and benchmark controls, plus effective live/checkpoint precision and actual layout in local diagnostics. Unsupported storage layouts, persistent assistant state, MiMo, native-block diffusion and Qwen4 selected-index state retain native encoding.
- Encode and restore older checkpoint rows with bounded CPU conversion, preserving exact recent rows and native recurrent/auxiliary state. Distinct layout/profile identities reject incompatible data. Restoring a native format does not recover precision discarded on disk or guarantee identical output or latency.
- Add matched-geometry encrypted-checkpoint qualification with real native-memory, cancellation, tenant-isolation and restart evidence. Keep exact-native replay controls separate from lossy output observations.
- Retain adaptive target-prefix MTP for explicit live-packed execution using measured unchained decode as its baseline; native targets retain their chained baseline. Preserve whole visual-block admission, native-owner feasibility accounting, and packed historical frontier restrictions.
- Enforce paged model capabilities independently of legacy prefix reuse, and reject invalid checkpoint precision settings on the native Diffusion path without enabling unsupported compression.
- Preflight live-packed Diffusion kernels before engine construction and include the native-recent feasibility bound in reported request capacity without adding runtime reservations.

### Supervised App Attest worker candidate

- Add a default-off, same-signed-executable App Attest worker candidate. Keep the inference key in the parent process, bind proof replies to their originating socket, and retire the owned worker before replacement without restarting inference.
- Fence update installation and restart on confirmed worker retirement and current lifecycle ownership. After a failed update, fresh verification can retry cleanup of the retained owner; terminal shutdown cannot reopen it.
- Preserve the exact worker opt-in in background `darkbloom start`; keep native diagnostic/fault flags out of the daemon. Reject the unused component-only transport-resumption scenario rather than reporting unproven success.
- Record artifact-bound native suspended-worker, loaded-engine assertion-callback recovery, and separate composed two-minute resumption passes. These results do not qualify later rebuilt artifacts or the full OS/security-transition and fleet-rollout matrix.

### Provider endpoint resumption

- Add protocol-1 endpoint-custody responses for same-process reconnects, using a fresh nonce per socket and the existing in-memory encryption key. Requires the matching platform implementation; does not grant local trust or extend Apple proof lifetimes.
- Make `darkbloom logout` drain and stop the provider before removing credentials, and attempt revocation of the saved provider token. Report unconfirmed remote revocation explicitly.
- Bind saved tokens to their issuer and roll back failed credential saves. Preserve revocation URL authority, ignore unbound stale PID occupants, and allow local logout when configuration is malformed.
- Enforce resume control-frame limits before decoding, while preserving large ordinary inference frames.
- Add an isolated signed-app diagnostic for native loaded-engine endpoint resumption. Reject runs that exit before their completion marker; align the retained threat model with the authoritative platform policy.

### Automatic official provider release registration

- Trusted CI tests, builds, signs and notarizes, then automatically registers the exact official build through the existing scoped release API before publication. Per-release hardware qualification and manual approval are no longer prerequisites; runtime Apple proof, receipt verification and permanent revocation remain enforced.
- Require verified signed annotated production tags in reviewed master ancestry and trusted master for dev/manual/recovery runs. Release jobs use existing repository secrets without environment approval attachments; shared security settings are unchanged. CI and repository writers are trusted for build identity, not proof that runtime Apple APIs work.
- Deploy the matching platform persistence change first. Publication retries reuse immutable signed artifacts without rebuilding or re-signing. No new endpoint, signing authority, hardware service, provisioning or automatic version bump is introduced.

### Provider release version ownership

- Validate provider packaging and retained-build recovery against `ProviderCore.version`, the signed release tag and the built binary. The frozen coordinator display version no longer blocks provider releases; signed-source, SDK qualification and immutable-artifact checks remain required.

## v0.9.19

Published 2026-10-08 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.19)).

### Demanded prefix reuse

- Retain bounded demanded checkpoint capture, retention and continuation from MLX-LM PR #289 within the newer merged SDK pin, including native cancellation retirement and typical MTP acceptance. Rebuild and validate the combined SDK and provider; earlier full-model measurements retain their recorded dependency pins and acceptance settings.
- Retain a distinct demanded shared-prefix checkpoint even beside the deepest checkpoint, within the existing three-boundary and memory limits. Give authenticated repeated checkpoints access to the reserved SSD write share on their first local appearance; unique extensions continue to use the novel share.
- Preserve the demanded native-contiguous frontier between the first and latest checkpoints, account for its actual backing allocation before capture, and retire displaced native owners through the tracked fence. A small MiMo fixture verifies reopened fork parity with real MTP off and on; full-model hardware qualification remains separate.
- Capture one aligned demanded boundary in eligible dense Qwen and the verified current Nemotron Lightning and Bonsai text prompts below the normal solo stripe, so repeated short prefixes can be published for reuse. Nemotron and Bonsai require their exact catalog IDs, weight aggregates and actual recurrent classes; Bonsai remains MTP-ineligible. Keep novel requests and other serving layouts on their existing geometry, and price the extra range in the first-content projection.
- Preserve the original proposed long-prefill endpoint when the benchmark-only demanded partition splits a range. Share bounded request-local continuation with first-content projection and restore it on rollback; abandon it on incompatible actual progress. Serving long stays disabled pending same-donor adjacent-frontier, output and cost qualification.
- Bound COMPLETE donation hashing by the checkpoint being written, preserving its authenticated address and backend endpoint rules while avoiding unused suffix work. Native-media addresses and ordinary lookup remain unchanged.
- Reuse immutable compiled prompt templates within the bounded contract cache and avoid fixture-only body/token copies during production planning. Keep request dates, prompt data, proof identity and render limits isolated.
- Reconcile first-content input-token budgets from current verified exact counts matching each serving renderer before preflight and dispatch, preserving the original arrival time, account/alias policy and earlier caller deadlines. Missing or conflicting renderer identity keeps the fallback clock; calibrated uncertainty and provider recount cannot extend the budget.

### Bounded cache holder matching

- Reduce dense cache-routing query copies by retaining the deepest compatible endpoint for each provider and tier. Preserve shorter valid fallbacks, complete hint values and matching/valid-holder counts; bounded scratch overflow restores the original path. The original source-bound synthetic dense workloads measured 43–46% lower CPU query time and 97–98% fewer cumulative allocated bytes; these are not new measurements of the merged coordinator or evidence of production cache-hit or model TPS gains.

### Autopilot daily earnings floor

#### Autopilot reward recording and authorization

- Evaluate reward authorization at the declaration's original server receive time, preventing later grants from qualifying an earlier day. Record consent independently of baseline computation and batch PostgreSQL cohort lookups so fleet size does not multiply socket-path database round trips.

- End new Autopilot floor accrual after November 7, 2026 UTC for every machine, regardless of opt-in date. November 7 settles at midnight November 8; pending rewards for earlier eligible days remain payable without resetting baselines or ordinary base rewards.
- Add a separately funded daily inference-earnings floor only for machines with saved Autopilot consent. Freeze the first-ever opt-in baseline from the exact preceding 168 hours, including sponsored inference. Machines with shorter earnings history use comparable mature machines with the same chip, performance tier and memory; no matching cohort leaves the baseline pending. The daily floor is 110% of the seven-day daily average, rounded down to whole micro-USD, and remains frozen through Autopilot off/on.
- Require trusted macOS 27 or later, at least two distinct downloaded eligible models and saved Autopilot consent at daily close, plus at least 90% uptime across each UTC day. Merge overlapping sessions and identity aliases when measuring uptime; unqualified days receive no top-up and do not consume the independent pool.
- Persist authenticated consent evidence, baseline and canonical-machine daily receipts across reconnects and identity aliases. Historical opt-in dates were not recorded by older software: unknown history requires an evidenced admin backfill, never a guessed deployment/reconnect date or a reset through off/on. Backfill does not create earlier consent or reward days. Earlier positive evidence linked after freezing exposes `history_conflict` and holds further payments without rewriting the baseline or finalized receipts.
- Add admin inspection, absolute pool-cap funding and baseline-repair endpoints. The independent cumulative pool starts unfunded, does not reset automatically and never pays a partial shortfall; pending funding retries recalculate income, while finalized days remain final. Payments default off and do not activate live Autopilot control. Provider publication and production activation remain separate approvals; existing accounting archives do not yet cover the new financial tables.

### Machine model diagnostics

- Extend the authenticated admin machine view with per-session reported pins, resident models, hardware, snapshot freshness and the running provider's Always ready/idle-timeout configuration. Unknown reports remain distinct from empty pin sets or disabled settings. These read-only diagnostics do not activate Autopilot, change pins or idle policy, or guarantee ready capacity.

### Machine-scoped Autopilot

- Persist each canonical machine's desired Autopilot mode in the database, defaulting to shadow. Admins list and edit machines through authenticated endpoints without a coordinator restart; live control still requires verified identity, provider consent and acknowledgement, with global shadow and pause overriding intent. Other machines retain ordinary serving and hypothetical planning; memory, pins and donor safeguards remain enforced.
- Distinguish desired machine mode from current session activity, and report live-cohort, acknowledged-live and shadow populations separately. Mode revisions revoke stale grants, failed policy reads remove live authority, and demotion preserves accepted-operation recovery. This change does not deploy or activate a production cohort by itself.
- Keep capacity freshness checks current across policy reads and durable command delivery, so slow database operations cannot extend a provider snapshot's lifetime.
- Keep lease enqueue from waiting on a concurrent socket close while holding registry/provider locks; shutdown still stops admission before draining queued frames, and in-flight cancellation waits for the transport fence.

### KV admission estimates

- Reduce ordinary engine concurrency when fixed recurrent or MTP workspace would otherwise consume its KV grant before any request can run. Heartbeats and local admission use the same memory-limited width; load and reserve-raise preflights preserve a serviceable workspace-aware grant, without lowering activation or minimum-KV safeguards.
- Estimate cold-model KV cost from fresh native reports for the same artifact and verified runtime instead of always using the generic bytes-per-token fallback. Live slot budgets remain authoritative; missing evidence retains the fallback, and provider memory checks still decide whether a load or request actually fits.
- Share cold-rate evidence once per fleet sample instead of scanning peers for every provider. Unused on-disk advertisements do not trigger forecast work, and registry read leases do not span donor walks.

### Withdrawal funding queue

- Queue confirmed withdrawals when Stripe payout funding is insufficient. Earnings stay reserved, the coordinator retries automatically, and Billing shows a Queued status. International exchange estimates refresh when queued payments are sent; uncertain Stripe outcomes keep their existing payment identity and funds reserved. Funding waits do not shorten the return-check and account-erasure protection windows after Global Payouts dispatch.

### Bedrock review and conditional merge clearance

- Support an explicitly approved ongoing OpenRouter budget with daily and per-attempt caps, retaining historical charges and unknown reservations. Preflight now rejects exhausted budget capacity even when provider funding is available.

- Limit scanner checkouts to trusted scripts and threat definitions so preflight does not spend its timeout fetching unrelated repository content.
- Preserve exact source coordinates in review excerpts and keep summaries below strict output limits. Require human review when the final model still reports uncertainty.

- Add attributed Bedrock review with bounded OpenRouter fallback, explicit usage reporting, and optional current-revision merge clearance. Medium/high findings, incomplete scans, and review-control changes require an independent formal security override. Cloud and merge-policy activation remain a separate verified rollout.
- Validate the enabled Sonnet 5.5 profile for the first pass and matching OpenRouter backup, retaining Opus 5.5 and Sol 6.1. Exercise the full production response schema in the bounded Bedrock smoke test and record the deployed configuration.

### SSD Write Endurance (Historical Preparation)

This candidate contains the SSD write-endurance correction below. The version
bump does not publish, register or deploy the release; full artifact qualification
and publication remain separate gates.

- Enforce the SSD prefix-cache write budget across cache instances, model reloads and provider restarts using a persistent root-wide rolling-day ledger. Charge serialized cache-file bytes, including encryption framing, before writing; exhausted budgets retain read access and report `write_rate_limited`.
- Forward `DARKBLOOM_PREFIX_CACHE_DISK_GB` and `DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` into newly installed launchd provider jobs.

### Provider restart and drain status

- Let `darkbloom restart` and `darkbloom stop` finish their graceful drain on a provider that has served native MiMo requests. The drain tried to retire the native owner once; after any served request that attempt only starts joining the finished request's consumer, so the drain reported `timedOut` with 0 unfinished requests within milliseconds, the command failed, and the service was left draining with automatic restart disabled. The drain now retries the retirement within its own deadline and reports `drained` once the owner retires.
- Report a provider that has stopped serving on `darkbloom status`. After a `stop`, `restart`, `start` or `update` drain that timed out, was interrupted or never relaunched, the old process stays alive and refuses new work, so the console shows it offline while `status` printed only `Daemon: running`. A `Not serving:` line now names the drain state and the commands that finish or interrupt it.

### Cache reliability

- Preserve healthy SSD checkpoints when missing-file reconciliation alone satisfies the disk limit, and retain same-tag publications across reconciliation. Keep AR allocation refusals cold until the SDK can prove native retirement completion before a shorter retry.

- Preserve negotiated healthy preload incumbents across interrupted response bodies and readiness-probe transport failures. Keep malformed completed reports fail-closed, and do not acknowledge newcomers or retain explicitly failed members after an uncertain partial attempt.
- Align preload model-ID validation with the registration request bound so an already accepted long identifier cannot disable unrelated verified contracts. Keep the explicit artifact allowlist and tokenizer capacity limits unchanged.
- Preserve negotiated preload incumbents through uncertain control transport completion, and keep configured catalogs above 128 models usable without expanding cache-routing allowlists or native tokenizer capacity.

- Bound retained cache-attempt bookkeeping by logical bytes as well as record count. Detach retained metadata, preserve receipt and dispatch ownership checks, and fall back to ordinary inference when the optional cache record cannot be admitted. Under byte pressure, reclaim up to 64 completed attempts' late-receipt grace records, never live ones, before refusing, and report retained bytes, refusals and reclamations as aggregate cache status fields and gauges.
- Preserve healthy verified prompt contracts when unrelated artifacts or preload members fail. Bind Go participation to the current catalog, child and exact verified set; keep strict preload reports, fresh partial-readiness confirmation, bounded retries and Rust replacement/cancellation ownership.
- Account for optional cache-planning decisions across the inference endpoints, recorded when a request's plan is first computed (during admission preflight for public requests), and keep planning within the original first-content deadline. Preserve eligibility, inference contexts and independent retry/receipt ownership. Legacy plan metrics keep their definitions; one population grows: a media request to a verified, preloaded model is now counted once as `ineligible` in `exact_cache_plan_total` / `exact_cache.plan` because the planner is consulted to record its decision, with no routing or billing effect.
- Align cache-planning client concurrency with sidecar workers and reserve health/control connection headroom under nondefault worker configurations. Bound waiting requests and payload bytes within the original deadline, preserving cancellation, independent health/control traffic, exact prefix identities and fail-cold behavior.
- Select a bounded, demand-driven tokenizer preload set when the verified catalog exceeds the configured loaded-contract capacity. Keep the full verified set within capacity, current Registry eligibility, fair replacement and failure backoff; do not raise the sidecar limit or wait for preloading on inference requests. Negotiate incremental tokenizer preload so healthy acknowledged contracts remain usable during a retry or selection change without exceeding loaded-contract capacity, keeping legacy fallback explicit and failing closed on protocol loss.
- Allow one bounded, fully authenticated shorter complete-checkpoint restore after a proven pre-allocation capacity refusal. Retire failed native/host owners before retrying, retain request/epoch fences and original remaining read/time budgets, and leave generic allocation, corruption and cancellation cold. No capture-cap, precision, encryption or first-attempt admission change.
- Reject substituted FIFO cache entries without blocking encrypted-cache read or touch operations; preserve descriptor-based path checks and regular-file behavior.
- Preserve surviving encrypted SSD checkpoints and routing announcements during routine active-store capacity/TTL eviction. Coordinate durable writes and index commits with retirement to prevent rename-to-index races without global invalidation. Keep destructive epoch fencing for unsafe changes, native authentication and bounded stale-hint invalidation.
- Refuse and retry SSD epoch checks when parent-directory opens or metadata status probes fail transiently, preserving the existing store's ownership. Continue disowning proven missing, substituted, malformed or oversized records; verify the original capability again when connected retirement observes an eviction.
- Use actual malformed files in the resident-preflight corruption fixture, retaining its no-I/O and corruption assertions; cover confirmed missing-parent status and typed `ENOENT` reads separately.

## v0.9.18

Published 2026-10-07 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.18)).

### Typical MTP acceptance

- Default eligible sampled target-prefix MTP requests to typical acceptance (delta `0.2`) when `[backend] mtp_acceptance` and the model override are absent. Sampled output is approximate, not distribution-exact; explicit `exact` restores exact acceptance and invalid values remain safely exact. Greedy behavior, native MiMo exact acceptance, disabled MTP and model eligibility are unchanged. Benchmark acceptance still defaults to `exact`; the recorded single-host B=1 runs do not qualify sampled quality or fleet-wide speed.
- Add per-model typical MTP draft acceptance for sampled requests (`[backend] mtp_acceptance`, `mtp_acceptance_by_model`), ported from mlx-serve PR #427. Greedy requests are unchanged; slot posture telemetry reports `mtp_acceptance`.
- Pin the merged SDK implementation from `mlx-swift-lm` main; its file tree matches the engine revision used in the recorded acceptance benchmarks.

### 0.9.18 Release Preparation (Historical)

The next provider release is prepared from changes merged since `v0.9.17`.
This is not signed-artifact qualification or a release announcement. Included
changes are detailed in the retained topic entries below:

- [Provider service replacement](#provider-service-replacement) (#1315), [shared-host memory admission](#shared-host-memory-admission) (#1264), and [system tool output readers](#system-tool-output-readers) (#1327).
- [Authenticated legacy enrollment](#frozen-legacy-mdm-authorization) (#1344), including the signed CLI eligibility check. Older providers cannot use the new authenticated reenrollment contract; coordinate the bridge rollout before publication.
- [Native queued cancellation retirement](#native-queued-cancellation-retirement) in the pinned SDK and [provider lifecycle coverage](#provider-test-coverage) (#1253).
- [MLX gather row tiles](#mlx-gather-row-tiles) (#1237), including the compiled nested MLX and regenerated Swift kernels. Changed numerical paths require fresh qualification; earlier full-model results do not qualify this candidate.
- Honor an explicitly configured `TMPDIR` for anonymous runtime metallib snapshots, preserving unlink-before-copy and digest binding. Invalid or unwritable explicit directories fail without falling back elsewhere (#1322).
- The merged [DevNet installer binding](#devnet) is included; pending provider build-environment and release-qualification PRs are not.

The bundled coordinator build fix aligns the digest-pinned Go builder and local
toolchain at Go 1.26.8, satisfying the unchanged `go.mod` minimum of 1.26.0.
Release Integrity now rejects missing pins, local/container drift and toolchains
below the module minimum. The bundled [upgrade safety changes](#coordinator-upgrade-safety)
add migration budgets, early trust preflight and a default-off soft-delete
mutation gate. Coordinator deployment and provider publication remain
separate approvals; see the [candidate rollout checks](docs/operations/provider-release.md#0918-candidate-rollout).

### Coordinator upgrade safety

- Add `EIGENINFERENCE_MIGRATION_TIMEOUT` (default `15m`) for the positive total `--migrate-only` deadline, and `EIGENINFERENCE_CONCURRENT_INDEX_LOCK_TIMEOUT` (default `1m`, minimum `1ms`) for all concurrent index builders on dedicated connections. Ordinary SQL DDL retains its 3-second lock and 10-minute statement defaults.
- Preserve invalid indexes and fail with operator inspection guidance, including legacy earnings indexes; never automatically drop a potentially active external build. Schema versions and financial semantics are unchanged.
- Validate production App Attest serving prerequisites before database access or migrations, reusing the later pre-freeze validator. Explicit development and actual opted-in memory-store startup remain exempt; database-only maintenance intentionally skips full application validation.
- Default `EIGENINFERENCE_SOFT_DELETE_MUTATIONS_ENABLED` to `false`, blocking new erasure confirmations (including `force`) and owned-provider removal with 503 `soft_delete_mutations_disabled` after authorization. Plan/status/cancel and accepted scrub/outbox work continue. Prior tombstones or erasures still require compatible fallback code; disabling the flag does not restore old-image compatibility. Production env refresh preserves explicit opt-ins.

### MLX gather row tiles

- Backport row-tile selection for `gather_mm` and `gather_qmm` in the provider's pinned MLX dependencies, with matching regenerated Swift kernel sources. Rebuild with a source-matched metallib; earlier full-model measurements do not qualify performance on these pins.

### Account erasure

- Keep upstream error text out of erasure-outbox manual-action logs; retain safe correlation IDs, target, state and attempt count, with details available in restricted outbox records.
- Exclude pending-erasure users from provider-email exports after machine-owner ranking, and retain a private `resend_contact` cleanup obligation before clearing the account email. Resend contact, segment and scheduled-broadcast cleanup remains manual.
- Route late memory-store referral settlement credits through the erasure-aware credit path, matching PostgreSQL: erased referrers stay at zero balance and receive a refused-credit audit record instead.

- Preserve successful account-erasure results when the caller cancels after commit, so confirmation and scrub still disconnect providers and clear runtime caches.

- Clear unshared APNs token proofs, pending challenges and push bookkeeping from runtime memory after erasure; fence delayed cache publication while preserving live shared keys and fresh ownership.

- Fence delayed App Attest proof and receipt writes, APNs token persistence, session backfills and admitted log uploads against completed erasure. Preserve shared live device ownership, clear the frozen runtime MDM cohort by account, and keep late Checkout referral codes local and tied to their original owner.

- Fence in-flight credential creation, provider persistence, financial admission and delayed Stripe responses against deletion. Preserve late external IDs for cleanup, strip late telemetry locations while retaining accounting, and remove frozen MDM cohort/hardware-interest records. Shared identities are removed after the last owner is erased; replayed refused refunds remain idempotent.

- Add admin account erasure (GDPR): `POST /v1/admin/accounts/{account_id}/erasure/plan` (dry run and a 15-minute confirm token), `POST …/erasure` (soft delete; `force` scrubs at once), `GET …/erasure` and `POST …/erasure/cancel`. The confirm call must repeat the token and the account email, and refuses while a withdrawal is in flight.
- The soft delete revokes the account's API keys and provider tokens, disconnects its providers and starts a grace period (`EIGENINFERENCE_ERASURE_GRACE`, default 30 days). A Privy login during the grace period gets 403 `account_pending_deletion`; after the scrub the same login creates a new account.
- The scrub removes emails, labels, serial numbers, MDA chains, locations, raw logs, App Attest proofs, referrer codes, Stripe IDs and the named wallet addresses in one checked transaction, forfeits the balance with an `erasure_forfeit` ledger entry, and queues the deletion of every Stripe account and recipient the account used. Rows of a Secure Enclave or App Attest key another account shares are kept. IDs and financial records stay.
- The confirm call repeats the account ID and the planned wallet list. A Stripe payout paid within 30 days still blocks erasure. After the scrub, any late credit is kept out of the balance and listed for review as `refused_credits`.
- An outbox worker deletes the Stripe Express account, closes the Global Payouts recipient, redacts Checkout Sessions with Stripe Redaction Jobs (public preview; waits when transactions are under 90 days old) and writes one `erasure_log` record to Datadog (tag `erasure_log:true`). Definitive refusals, exhausted retries, stuck jobs and Checkout Sessions Stripe cannot find (each on its own row, the rest of the batch continues) end in `manual_action` for an operator; `GET …/erasure` shows each row's state. Each delivery claims its row just before contacting Stripe; expired workers cannot overwrite newer progress or create duplicate manual-action rows. Permission failures, invalid-account responses and ambiguous 404s retain the Stripe account ID for manual resolution rather than reporting deletion as complete.

### Pull-request stack tooling

- Add a checked, signed same-tree ancestry repair for dependent PRs after each parent squash, with atomic non-force pushes and optional retargeting. Document linear bases, manual reconciliation on content differences, and renewed signature, CI and approval checks; the tool does not merge PRs or automate conflict resolution.

### Personal data in coordinator logs

- Stop writing email addresses, IP addresses, device serial numbers and MDA UDIDs to coordinator process logs, which are forwarded to Datadog. Log lines name accounts by `account_id` (`user_id` in the access log) and providers by `provider_id`; the access log no longer has a `remote` field and the MDM webhook debug line no longer includes a body preview. Logs written before this change are not affected.

### System tool output readers

- Fix a hang in provider code that runs a system tool and reads its output, such as hardware detection for `darkbloom beta`, `autoupdate` and `models location`. When every Swift concurrency thread waited for a tool at the same time, the output readers got no thread, so the wait did not end. With a timeout, the call failed as timed out. Each output reader now has its own serial queue.

### Generated API-key queries

- Generate the coordinator's API-key queries with sqlc from the checked-in schema; `make sqlc-check` fails CI when the generated code or the schema file is stale. API-key behaviour does not change.

### Coordinator schema migrations

- Apply the coordinator's Postgres schema as numbered goose migrations instead of re-running every DDL statement at each boot. The first boot applies and records the existing schema as version 1; later boots apply only new versions. SQL migration statements stop waiting for a lock after 3 seconds and make up to three attempts, and coordinators that start together take turns on an advisory lock.
- Fail startup without recording the baseline when a required schema statement fails, so a later startup retries missing columns. Preserve current consumer-settlement, legacy MDM cohort, small-model interest and Stripe refund-index schema changes as subsequent versions.
- Check in the schema as `coordinator/store/postgres/schema/schema.sql` and test that the migrations build exactly that schema. New schema changes go in a new numbered migration file.

### Soft-delete schema

- Prepare account erasure: add `deleted_at` to users, API keys, provider records and provider tokens, hide soft-deleted rows from every live read, let a Privy user sign up again after erasure, index the erase paths, and cascade referrer code changes to referrals. Account erasure and ordinary provider removal write `deleted_at` behind the [mutation gate](#coordinator-upgrade-safety). After these migrations run, roll back only to compatible goose-based coordinator images.

- Exclude soft-deleted users from small-model interest exports before pagination, and exclude deleted users and provider records from initial legacy MDM cohort qualification. Repeated cohort reads preserve the frozen snapshot.
- Suppress stale registry-supplied provider locations in memory-store usage flows when the stored provider record is soft-deleted.

### Stripe refund clock skew

- Refund a rejected Stripe withdrawal when the coordinator clock is ahead of the PostgreSQL clock. Before, the refund check missed the withdrawal debit, refused the refund, and the recovery loop and `payout-audit --apply-refund` retried without success. The check still credits each withdrawal at most once and still refuses a ledger that does not show the exact debit.

### Nightly Linear workflow

- Package one-time Codex setup and a nightly playbook that reconciles work from Codex, Claude Code, and Pi with each teammate's Linear. Reuse existing issues and route unclassified deliverables to Others.
- Fetch shared skills from the configured repo branch on every trigger while keeping personal settings and recovery state local. Include offline updater tests; teammate installation and live automation remain separate rollout steps.

### Stale cache allowlist entries

- Report cache-routing allowlist entries that a model revision has left behind. Publishing new weights or a new template under the same model ID changes the artifact tuple, so the model silently lost cache routing and its cache hits fell to zero until an operator appended the new tuple. `GET /v1/cache/status` now counts such models as `artifact_allowlist.stale_models`, with matching Prometheus and Datadog gauges, and the coordinator log names each live tuple once. Routing behaviour and the allowlist's exact-match rule are unchanged.

### Mac CI cost controls

- Cancel superseded pull-request CI and integration runs without cancelling default-branch pushes. Bound provider unit-test stalls with the existing diagnostic watchdog, and reuse compatible integration build caches while retaining every test gate and parallel job.

### Archived analytics reader

- Add bounded asynchronous historical SELECT submission, polling, pagination and cancellation over pinned archive catalogs. Keep query results private and source retirement disabled while preparing the 14-day completed-detail storage plan.
- Allow explicit recapture generations, shard large completion catalogs, enforce replay deadlines and verify reused BigQuery catalog contents before publication.
- Pin and validate prior coverage before republishing, rejecting altered or duplicate catalog rows rather than incorporating them into a new verified digest. Unverifiable legacy catalogs fail closed without changing reader aliases.
- Add an opt-in validated local snapshot path for leaderboard, network totals and network series with source freshness checks and 503 responses when unavailable. Persist accepted source cutoffs and generation checksums in a separate private state file; snapshot mode fails closed if that file is missing or corrupt.
- Refresh database-backed network totals every 5 minutes with a 15-minute stale-success ceiling and cache successful network series for 5 minutes. Preserve shared top-200 leaderboard caching, failure cooldowns and the 30-second stats refresh.
- Reconcile aligned usage buckets across public series and reject reused BigQuery external tables whose manifest, configuration or schema differs from the verified publication.
- Replace the earlier telemetry-only retirement proposal with a 14-day completed-detail target covering telemetry and accounting. Keep active state and financial replay fences operational; continuous capture, broad reader migration and source retirement remain unimplemented and disabled.

### Provider test coverage

- Report Swift product, CLI and benchmark coverage separately in CI, merging isolated test-process profiles without replacing test failures with coverage results.
- Expand provider and standalone lifecycle, tiny-model loading, CLI/service/fan, SSD-cache and benchmark harness regressions with temporary state and scripted host boundaries. Keep real tiny-model execution distinct from full-checkpoint quality and performance qualification.

### Provider email campaigns

- Add the `provider-emails` operator command to preview provider software/macOS update audiences, sync owner groups to Resend, render and test notices, and create unsent broadcasts for review. Preserve unsubscribe preferences and remove owners from managed groups when their reported machines meet the target.
- Serialize campaign reply-to addresses in the Resend broadcast API's array form while keeping the campaign configuration's single-address input.

### Autopilot inventory reporting

- Add an admin-only connected Autopilot inventory report with exact per-model last-reported approval counts, deduplicated approval totals and a models-per-provider distribution. Distinguish unpaused, paused and stale connections without exposing provider identities or claiming fresh disk verification, residency or routing eligibility. The read does not depend on the operation ledger.

### Open Sales Program

- Add an Open Sales Program page to register and share a code, apply a referrer, and track referred consumers and earned rewards. Preserve referral links through sign-in and invite redemption.
- Reward referrers with 5% of their referred consumers' collected token spend as withdrawable earnings funded by Darkbloom. Consumer prices, provider earnings, and platform-fee credits remain unchanged.
- Settle consumer charges and referral credits atomically per request, excluding free or uncollected usage and preventing duplicate rewards. Keep attribution immutable and prospective; retire the old platform-fee-share setting.
- Include only the paid portion of token-promotion requests in referral earnings, atomically with promotion settlement.
- Exclude execution on the consumer's own machines, explicit self-routing, and selected-machine routing from referral rewards and eligible-spend totals, including paid owner-preferred fallbacks. The same exclusions apply to the paid portion of promotion requests. Request billing, provider payouts, and promotion grant use are unchanged.
- Require Privy sessions for referral mutations and retry uncertain settlement without releasing reserved service funds or repeating live-request accounting. Reconcile pending settlements during graceful shutdown.

### Routing scan cost

- Compact retained routing evidence, reuse bounded private reservation storage, borrow forecast inputs, project alternate-selection values once, and aggregate pending work once per provider snapshot. Public scan and quote lifetimes, selection policy, admission, retirement and billing behavior are preserved.

- Reduce the per-request provider scan cost after the coordinator reorganization. Autopilot eligibility reads the clock only for a provider holding a matching control grant, candidate ranking reads the projected pool in place, and candidate storage fills one allocation size class. Routing outcomes are unchanged.

### Canceled PostgreSQL debits

- Keep a PostgreSQL debit uncommitted until its statement succeeds, preventing a timed-out row-lock wait from later becoming a charge. Lost commit acknowledgements remain uncertain and must not be blindly retried.

### Shared-host memory admission

- Add opt-in `DARKBLOOM_MEMORY_AVAILABILITY=free-only` to exclude inactive pages from shared-host admission and KV headroom. Sampling failures fail closed in this mode. Preserve the default reclaimable-page policy and document what the memory reserve measures.

### Verification concurrency

- Keep a reconnected provider's verification job eligible after its old worker releases the claim. A delayed challenge callback no longer restores the stale running snapshot and postpones verification until claim expiry.
- Read one synchronized trust-level snapshot for registration metrics and telemetry while verification updates run concurrently.

### Provider service replacement

- Wait for launchd to confirm removal of the previous provider service before installing or starting its replacement. Preserve stop/uninstall intent and report failed or timed-out removal without starting another service.
- Treat bootstrap operation-in-progress errors as failures instead of reporting a successful start.

### DevNet

- The dev coordinator host is now `api.dev.darkbloom.dev`. The old dev host `api.dev.darkbloom.xyz` is retired. The provider does not accept an MDM server on `darkbloom.xyz` as a Darkbloom MDM server, and `deploy/provider-fleet/update-fleet.sh dev` uses the new host.
- An installer served by a coordinator other than production (for example dev) now writes that coordinator's `[coordinator] url` into `~/.config/darkbloom/provider.toml` and keeps the file's other settings, so `darkbloom start`, `login`, `update`, the LaunchAgent and the watchdog connect to it instead of production. The production installer removes that `url` line (and creates no file), so a Mac bound to dev returns to the production default. A running provider changes coordinator at its next `darkbloom start`.
- Add `coordinator/cmd/devnet-seed`, which fills an empty dev database with fake accounts, API keys, provider sessions, usage, ledger entries and balances. It refuses a database whose `users` table has rows.
- The dev VM boot path now sets `EIGENINFERENCE_IPAPI_KEY`, as `deploy/gcp/refresh-env.sh` already did.

### Leaderboard availability

- Add a concurrent BRIN time index for recent provider-earnings rankings, enable range autosummarization, and keep planner statistics current. Return an uncached 503 when ranking queries fail instead of showing and caching an empty leaderboard.
- Share one top-200 ranking fill across caller limits and equivalent window aliases. Coalesce concurrent misses, pause failed fills for 10 seconds, and include the remaining retry delay in leaderboard 503 responses.

### Cache reliability

- Remove caller-supplied top-level `user`, generic `metadata`, `safety_identifier` and `prompt_cache_key` from provider-bound inference bodies across direct, queued and retried requests. Preserve nested content, inference controls, coordinator response metadata, authenticated account ownership and cache controls; this does not anonymize prompt content.

### Frozen legacy MDM authorization

- Freeze a durable authenticated account/SE-key/serial cohort of already successfully MDM-verified devices on the first upgraded coordinator startup after revocation replay. Restarts preserve even an empty cohort; new accounts/devices and new associations cannot expand it. Gate identity recovery, scheduling, live/late MDM results and cached trust reuse. No grace period has been chosen and no expiry is implemented.
- Require a linked provider Bearer token and fresh signed SE-key proof for `/v1/enroll`; reenrollment is limited to the existing key under its frozen account. New identities require qualified App Attest, with no unsupported-OS fallback. Generic copied profiles can still enroll directly in MicroMDM; the restriction guarantees coordinator MDM authorization, not prevention of that direct enrollment.
- Require App Attest for noncohort owner self/prefer routing as well as public serving. Validate enabled production App Attest serving with full rollout before the startup freeze; invalid configuration fails closed without freezing membership.
- Require macOS 27 or later and current qualified App Attest authorization for base rewards for every provider, old or new, including machines with both MDM and App Attest evidence. The OS claim must belong to that same authorization; missing, malformed or older versions fail closed. Legacy MDM-only machines remain eligible for grandfathered serving but not base rewards. Existing economics guards and inference/work earnings remain unchanged, with no retroactive reward clawback.
- Check authenticated frozen account/key eligibility in `darkbloom enroll` even when a legacy profile is already installed; a successful check preserves that profile without reinstallation. Clarify that new providers need macOS 27 or later and current qualified App Attest, not an OS-only grant; consumers have no macOS 27 requirement.
- Update the enrollment HTTP integration fixture to verify a linked test token and canonical P-256 proof instead of expecting anonymous profile downloads.
- Drain eligible account-scoped historical inventory in 100-row batches before the first cohort freeze, within the existing 30-second startup deadline; errors or cancellation leave no new freeze marker. Preserve existing evidence and alias rules, exclusion of insufficient history, and the inability of later aliases to widen a frozen cohort.
- Keep the production cutover fail-closed while allowing explicit development and actual opted-in memory-store startup without freezing a cohort; deployment classification defaults to production and does not use telemetry tags.
- Retry transient provider-token store failures instead of misclassifying credentials: WebSocket registration closes with retryable 1013 and enrollment returns 503. Invalid or revoked credentials remain unauthorized.
- Stop anonymous installer profile requests; defer eligible legacy reenrollment until after installation through account login and the signed CLI eligibility check. Existing management is preserved, and new-provider macOS 27+/qualified App Attest guidance remains explicit.

### Native queued cancellation retirement

- Fix a pre-existing SDK race exposed during prefill-deadline validation: concurrent cancellation could remove a queued native request without retiring it, leaving its reservation charged. Use one cancellation decision for retirement and queue removal; retain exactly-once completion and reservation release after retirement.

### Budgeted advisory PR review

- Give PR authors Sonnet feedback before selective Opus/Sol 6.1 depth, reuse unchanged analysis, and debounce follow-up pushes. Show clean results, coverage, cost and saved historical findings in the advisory comment.
- Reserve shared spending before every provider request; cap normal/deep attempts, PR/day, repository/day and the ten-PR pilot. Preserve partial findings and unknown-cost reservations after failures. Paid scanning defaults to disabled; maintainers can preconfigure activation before merge after state-writer and funding verification.
- Keep findings citable across large diff fragments and publish a compact history link when the full report exceeds comment capacity.

- Add a manual activation preflight that verifies signed state writes and provider funding without paid model calls or changes to the spending ledger. Support a repository-scoped App writer with short-lived tokens; keep private funding details out of public preflight logs.

### Console chat request budget

- Refuse oversized chat requests locally with guidance to reduce images or conversation length. Check the full UTF-8 request and optional encrypted envelope before sending, retain the user's message and images, and apply the same check on retry. Existing per-file and image-count limits remain unchanged.

### Canceled queue waiters

- Stop canceled waiters held by a scheduling pass from returning as queued demand and occupying slots needed by fresh requests. Drop completed entries during queue pop and stale cleanup while preserving live FIFO order, timeout notifications, and reservation cleanup.

### Durable hardware interest

- Save Earn-page notification interest against the authenticated account before showing confirmation. Both notification buttons preserve pending hardware through sign-in, expose cancellation and retry, and recover confirmed status from the server after reload.
- Add per-account memory/Postgres upserts and a bounded admin-only export joined to current email. Hardware updates replace the account's previous selection; legacy anonymous browser markers no longer claim registration. No email delivery is added.

### Bounded non-streaming responses

- Bound coordinator retention of non-streaming provider output by aggregate bytes and frame count, including empty frames and the first chunk. Oversized attempts are cancelled and fail with 502 before successful settlement; streaming behavior is unchanged.

### Idle provider routing recovery

- Let idle providers with missing or stale measurements compete using fleet-median prefill and decode rates, replacing each rate independently while preserving reviewed profiles and deadline confidence. Expire independently dated decode estimates after 30 minutes only on loaded, idle providers with no pending work. Selection is not guaranteed, and physical admission remains unchanged.
- Back off failed exploration attempts and retain corroborated slow-rate evidence across reconnects, without treating deadline refusals as provider-health faults. Median-priced requests also feed back when they have no deadline or contain vision input. The TTFT calibrator does not learn from median-priced predictions.
- Deduplicate retained observations across reconnects, preserve newer healthy clears during identity merges, and treat explicitly missing performance evidence separately from an undated legacy EWMA. Replayed or invalid metadata cannot manufacture slow-rate corroboration.

### CI and contributor workflow

- Report coordinator statement coverage from the e2e tests as its own job-summary row, and keep the lane data as the `coordinator-e2e-coverage` artifact. The e2e lanes instrument the production coordinator packages only, as the coordinator test runner does, and both coverage reports use `scripts/coordinator-statement-coverage.sh`. The tests and their pass/fail rules do not change.

## v0.9.17

Published 2026-10-02 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.17)).

### Provider 0.9.17

- Keep the normal startup selection and explicit `--model` override authoritative while Autopilot is waiting or observing in shadow. Cached planning inventory can no longer make ordinary routing load unselected models.
- Separate cached candidates from serving advertisements in Autopilot protocol 3; retain full shadow planning and require an acknowledged live lease before additional models become loadable. Older coordinators keep the selected models serving without activating the new protocol.
- Preserve normal selected-model successor updates independently of Autopilot inventory, and show the serving selection in My Macs instead of observational candidates.

## v0.9.16

Published 2026-10-02 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.16)).

### Provider 0.9.16

- Offer the Autopilot yes/no choice on every normal interactive start, using the saved choice as default and retaining the normal startup model and memory selector, including explicit `--model` selection.

- Fix enrolled providers appearing stopped, rejecting graceful stop/restart, and accumulating false failed-start rollbacks because their Autopilot snapshot could not be decoded. Preserve heartbeat readability for a watchdog still running 0.9.15 during upgrade.
- Name each model during cached-inventory verification and report a busy model immediately instead of silently waiting behind a background revision update. Saved enrollment and the running provider remain intact when ordinary startup verification fails.

### Status page placeholder

- Add a standalone static status-page placeholder: "The status page will return in the future." Publishing it requires a separate hosting change; the existing Instatus content is preserved.

## v0.9.15

Published 2026-10-01 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.15)).

### Provider availability wizard

- Add `darkbloom start --schedule` for optional interactive background setup and `darkbloom schedule` for editing saved settings without starting or stopping the provider. Support saved windows, overnight/weekend presets, custom add/edit/remove, inspection, disabling and custom config paths.
- Offer preloading at window opening or on-demand loading using the existing startup-preload setting, preserving model selections and idle policy. Reject invalid enabled schedules before serving, merge overlapping/adjacent windows, honor local-calendar DST boundaries and keep full-week availability connected continuously.

### Self-service bank payout migration

- Add an explicit Global Payouts cutover for all supported bank destinations. Existing Connect users complete their own bank setup; history, earned balances and legacy account references are retained. US bank setup uses local transfers.
- Separate legacy Connect credentials and connected-account webhook verification from Checkout. Current and legacy Checkout events settle atomically without duplicate deposits.
- Recover verified rejected-transfer refunds atomically, require exact Stripe payout evidence during cutover, and check financial-account funding plus fees before new payout debits. Add a bounded audit tool and explicit, operator-verified historical refund repair.

### Nemotron parser and artifact defaults

- Absorb stray `</think>` markers in Nemotron Lightning content without changing other native-channel families or interpreting markers inside tool arguments.
- Apply Nemotron's artifact-declared sampling defaults only to omitted request fields; explicit values still win. Admit the hybrid8 and rollback concrete build IDs without changing the catalog or activating either build.

### Nemotron prompt fidelity

- Preserve function-level `strict` for Nemotron tool prompts and align the pinned Nemotron template's scalar/JSON filters with Transformers. Other model families retain their existing rendering and tool normalization. This repairs prompt fidelity, not all reasoning-off tool-selection failures in Q4.
- Keep numeric Nemotron values identical between provider rendering and exact-cache planning, including exponent formatting and the SDK's integral-number conversion. Apply non-Nemotron `strict` stripping to native media tool inputs as well as text; pinned metadata-only parity gates cover the reference and numeric edge cases in CI.
- Advance prompt normalization to v8 and renderer identity to v4 across provider and coordinator, retaining normalization v7 policies. This invalidates prompt-contract/cache identities for all families; regenerate sidecar contracts and allowlists together before rollout. No model weights, sampling defaults, tool-choice policy, or inference kernels change.

### MiMo SSD prefix-cache hits reuse the prefix

- Fix: every native MiMo V2.6 SSD prefix-cache hit was discarded. The bridge stages a checkpoint under a placeholder engine request ID and mints the real ID just before submit, and the SDK's native import check compared engine IDs, so each staged checkpoint was refused (`unsupportedConsumer`) and the request prefilled its whole prompt again. The pinned mlx-swift-lm binds a stage to its submission receipt instead. On a 256 GiB M3 Ultra, a repeated 6K-token prompt now reaches its first token in 4.5 s instead of 13.1 s, and a 12K-token prompt in 4.6 s instead of 27.3 s, with byte-identical output (MTP off and auto).
- Report `prompt_tokens_details.cached_tokens` from the standalone server only when the engine actually reused the prefix. A matched checkpoint whose adoption failed or was skipped previously still reported its matched tokens. Coordinator usage already came from the resolved lookup and is unchanged.

### Experimental model Autopilot

- Add default-off experimental Autopilot enrollment at provider startup. Yes or `--autopilot` skips the picker, discovers/verifies all eligible already-downloaded active network models, and records shadow consent without activation or downloads. Exclude arbitrary local/off-catalog, retired, ineligible and unverified builds; empty inventory fails before restarting. Preserve all saved serving, preload, idle and other preferences.
- Default coordinator Autopilot to observation only. It records hypothetical plans without residency reservations, fences or commands; explicit `EIGENINFERENCE_AUTOPILOT_OBSERVE_ONLY=false` enables a separately approved live rollout. Preserve the enable switch and runtime admin pause.
- Add Autopilot status, pause/resume, pins and disable; session-bound live control, selected-model boundaries, request-shape planning, retained load timings and durable operation records. Active control preserves files, local work and donor capacity.
- Keep approved cached inventory static across ordinary restarts. Explicit `--autopilot`, `autopilot enable` or `autopilot models` refreshes verified eligible cached models without picker/downloads; `--all` remains network-gated and enrollment with `--model` requires opt-out. A later live rollout chooses cached models to improve utilization, not guaranteed earnings.
- Deduplicate unchanged shadow proposals as first-write decision records, not a per-tick time series; the current summary stays fresh even when an unchanged decision ages out of recent history. Distinct state/session/revision decisions remain retained; live command IDs are unchanged.
- Reject coordinator unload victims outside the approved cached inventory while preserving guarded local superseded-model cleanup. Filter invalid UTF-8 ID bounds before verification, then validate the normalized verified inventory count before saving consent or draining; invalid inventory cannot stop the existing daemon or install a replacement.
- Preserve an enrolled provider's pause during ordinary start, `enable` and inventory refresh; resumption requires explicit `resume`. Validate saved inventory all-or-nothing before persistence/drain, including transient verification failures; only explicit refresh may prune excluded builds.
- Apply current full Autopilot settings at each new scheduled window. Disabling between windows restores ordinary saved model selection even if unchanged; other runtime inputs remain frozen.
- Queue pending-operation uncertainty before removing a disconnected provider, persisting outside registry/provider locks. Connection loss never implies rollback or a confirmed terminal resident set.

### Automatic MiMo Calibration (Historical Preparation)

- Calibrate idle native MiMo engines after model loading and refresh stale phase evidence with uncached built-in prompts. Measure short and 4k text plus affordable batches within the existing concurrency cap; retain the production MTP and memory configuration.
- Give customer requests priority across models: cancel calibration and wait for real native retirement before admission. Keep probe work out of served-request/token counters; publish actual phase measurements and optional peak-concurrency workload buckets through existing heartbeats.
- Align `ProviderCore.version` and the coordinator latest-provider display fallback at `0.9.15`. Publication, signed-artifact qualification and coordinator rollout remain separate operations.

### Provider prefill evidence recovery

- Let an idle native text provider renew expired isolated-prefill measurements through one short request under its original first-content deadline. Serialize the final idle check and native registration, then restore ordinary concurrency after prompt completion while retaining service and memory ownership until actual engine retirement. Back off failed or cache-only recovery; busy, loading, media and large requests retain predictive admission.
- Reseed measured phase EWMAs after an evidence gap while preserving sample identity/counts. Unchanged heartbeats cannot manufacture current prefill evidence.

### Native media prefill observations

- Retain native MiMo target-decoder prefill rates in dedicated numeric workload buckets, separated by computed suffix, context, reuse and overlap. Encoder preparation remains outside this timer. These observations support media calibration without mixing media into text rates or changing first-content deadlines.
- Price prepared native media from fresh observations of the same engine and observed prompt range. Keep queued text at its own conservative rate. A single idle native request can gather missing evidence under the original deadline, retaining ownership through real retirement. Failed or ineligible attempts back off for two minutes; an eligible sample opens the next shape after retirement.
- Pin the provider SDK to merged `mlx-swift-lm` main commit `e31a173` (#208) for native-media deadline evidence.
- Keep deadline-rate evidence invalidated when native media fails during later retirement, even after successful preparation; preserve the qualified text policy's separate recovery requirements.

### Native media prompt accounting

- Estimate concrete MiMo image/video/WAV prompt work from bounded media metadata and verified processor configuration. Reconcile fetched-media input quota and deadline token terms from the original request arrival; retain heuristic fallbacks and provider admission safeguards.

### Exact rectangular MTP for native MiMo

- Make exact rectangular verification the default MiMo MTP strategy. Rectangular verification scores all draft columns in one `[1, 1+k]` forward, but MLX's 2–7-row affine matmuls on M3-class GPUs use `qmv_wide`, whose reductions differ from one-row decode, so the bulk trunk was never output-identical. Scalar-dense rows (row-local router, serialized attention) with a new row-exact multi-row projection that keeps one-row `qmv_fast` arithmetic while streaming each weight once reproduce serial decode exactly. On a 256 GiB M3 Ultra, greedy MTP-on decode measured about 49 tok/s at short prompts and 46–48 tok/s at 4K prompts, against about 44.9 / 42.8 tok/s with MTP off and about 39 / 37.7 tok/s with serial MTP; 20K and 50K prompts decode at parity with MTP off. Greedy and reasoning outputs and audio responses were identical to MTP off. Media rows stay target-only, and a serving engine that cannot arm the scalar-dense scratch never drafts.
- `DARKBLOOM_MIMO_RECTANGULAR_VERIFY=0` (or `false`/`no`/`off`) or `DARKBLOOM_MIMO_RECTANGULAR_SCALAR_DENSE=0` selects serial-target scoring; `DARKBLOOM_MIMO_ROW_EXACT_PROJECTION=0` keeps exact verification with one matmul per row. All three are forwarded to the launchd provider job. The native paged profile stays serial-target.

### Native MiMo decode kernels and adaptive MTP

- Enable the native MiMo short-forward decode kernels by default: fused residual/RMS norms, distinct-expert MXFP4 decode and the FP32 router GEMV. Each matches the stock operation it replaces for its supported one-request 1–7-row shapes and falls back everywhere else. They were exact-`1` opt-ins that no LaunchAgent forwarded. On a 256 GiB M3 Ultra with MTP off, single-stream decode rose from 41.5–42.0 to 45.2–45.6 tok/s (short prompts) and from 40.4–40.7 to 42.8–43.4 tok/s (4K prompts), with greedy output identical on 8 short and 5K/9K-token prompts. `DARKBLOOM_MIMO_FUSED_DECODE_NORMS`, `DARKBLOOM_MIMO_DECODE_EXPERTS` and `DARKBLOOM_MIMO_DECODE_ROUTER_GEMV` accept `0`/`false`/`no`/`off` as rollbacks and are forwarded to the launchd provider job.
- Keep native MiMo's adaptive MTP from launching serial-target draft rounds. Serial scoring evaluates every draft column with one ordinary target forward, so those rounds cannot outpace target-only decode; one process that locked onto depth-3 serial rounds decoded greedy requests at 25–27 tok/s. MTP stays on and active with live assistant history; explicit rectangular verification keeps its adaptive depth.

### CI and contributor workflow

- Explicitly enable SSD caching for the exact-cache E2E development checkpoint and establish repeat demand before expecting a donation. The gate now requires exact cached output, account isolation and recovery to pass; CI no longer ignores its failure.

- Set up Homebrew in the macOS integration and benchmark workflows with `scripts/setup-macos-homebrew.sh` instead of the `Homebrew/actions/setup-homebrew` action. The organization Actions policy does not allow that action, so both workflows stopped at startup. The script uses an installed `brew` or installs Homebrew from a pinned, checksum-verified installer.

### Coordinator first-content routing

- Read serving-slot metric attribution from the already-selected provider after dispatch, avoiding a redundant registry lock that could delay first content. Keep backup and terminal-fault attribution rules intact.

## v0.9.14

Published 2026-09-30 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.14)).

### MiMo SSD Prefix Caching (Historical Preparation)

- Enable encrypted text-only COMPLETE-prefix SSD checkpoints by default for exact `mimo-v2.6-flash-mopd` and `EigenLabs/MiMo-V2.6-Flash-MOPD-MLX-4bit-mtp` identities. Keep verified artifact/runtime identity, tenant isolation, native ownership, memory admission, SSD limits and cold fallback.
- Preserve image, audio and video serving through the existing joint contiguous path; media requests remain uncached. RAM retention, native paging and rectangular verification remain separate opt-ins.
- Forward `DARKBLOOM_MIMO_COMPLETE_PREFIX` to the launchd provider job. Unset or empty uses the model default; exact `1` enables this gate and any other nonempty value disables. Unlisted IDs also require affirmative `DARKBLOOM_PREFIX_CACHE`; `DARKBLOOM_PREFIX_CACHE=0` still disables all prefix caching. Apply shell overrides with replacement `darkbloom start` so its saved plist is refreshed.
- Align `ProviderCore.version` and the coordinator latest-provider display fallback at `0.9.14`. Publication, full-artifact cache qualification and coordinator rollout remain separate steps.

### MiMo media memory and text isolation

- Complete native MiMo vision work one frame and transformer block at a time, reserving the largest live working set instead of every layer and video frame together. Preserve retained media/features, KV, codec and OS/activation safeguards.
- Match vision scratch to the selected fused Metal kernel and complete audio encoder/RVQ stages before reusing their workspace. Reserve actual audio tiles rather than charging a maximum tile and every layer simultaneously.
- Report media-preparation memory refusals as `media_memory_unavailable`. Keep bounded failover while leaving text-capacity clamps, health breakers and reputation unchanged. Genuine native completion faults retain their existing quarantine behavior.
- Add exact OpenRouter JPEG/MP4/MOV fixture coverage and media-refusal-to-text-serving regressions.

## v0.9.13

Published 2026-09-30 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.13)).

### MiMo Memory Admission (Historical Preparation)

- Accept bounded AAC audio in MP4/MOV and mono/stereo PCM8/16/24/32 and Float32 WAV input from 8–192 kHz for MiMo audio. Preserve sample rate and channels for the native resampler, reserve all decoded/resampled samples, and qualify the authenticated path with the genuine audio codec before release.
- Accept OpenRouter's Boolean `chat_template_kwargs.thinking` alias in the provider and coordinator normalizer, preserving canonical control precedence and reasoning history.

- Budget native MiMo grouped-prefill candidates across the configured concurrency, including fixed target rings, MTP workspace, the engine watermark and minimum useful KV space. Fall back to a smaller or ungrouped profile when the full reservation does not fit.
- Reduce native MiMo concurrency after memory-grant shrinkage instead of reserving workspace for unavailable slots. Preserve retained engine reservations, enforce the same cap on provider submission, and refuse new loads or reserve raises that would strand an existing native engine below one serveable request.
- Price native MiMo pixel preparation from actual request geometry rather than the machine-sized configured ceiling. Count video attention scores independently per temporal frame; preserve full lazy-graph, allocator, and native ownership safeguards.
- Correct native MiMo image/video admission to charge all retained RGB plus the largest sequential decode workspace. Release temporary image/frame objects each iteration and convert video BGRA directly to RGB; video no longer reserves a decoded raster for every unsampled source frame. Preserve transport, pixel, native-workspace, KV and OS memory gates.
- Align `ProviderCore.version` and the coordinator's latest-provider display fallback at `0.9.13`. The coordinator keeps enforcing reported token budgets and per-model concurrency; no admission bypass or production configuration change is included. Publication remains a separate operation.

### Native MiMo standing wired residency by default

- Enable native MiMo standing wired residency by default. Without a standing residency set every command buffer must make the ~161 GiB weight payload resident again; on a 256 GiB M3 Ultra the driver kept unwiring it and single-stream decode measured ~0.4 tok/s (the request failed at 234 s), versus 37.8 tok/s with residency, identical requests and weights. The existing bounded ceiling still leaves max(16 GiB, 10%) of physical memory unwired and never grants load admission. `DARKBLOOM_MIMO_PERSISTENT_WIRED_RESIDENCY=0` (or `false`/`no`/`off`) restores the previous behavior and is now forwarded to the launchd provider job; the former opt-in value `1` remains valid.

## v0.9.12

Published 2026-09-30 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.12)).

### First-content evidence exploration

- Let an idle, loaded provider compete beside feasible peers after the 5-minute measurement-age threshold, using connection age when measurements are undated. This breaks the evidence-first exclusion of newly connected and long-idle providers without guaranteeing selection or measurement recovery. Hedge and fresh-feasible requests still require feasible evidence.
- Treat outstanding service-retirement leases and reported service usage as busy even when slot counters are idle, and recheck exploration eligibility at atomic reservation. Older providers can still qualify using their existing slot telemetry.

### CI and contributor workflow

- Run provider unit, SDK and prompt-parity checks on independent workers with compatible build caches, retaining MiMo fixture preparation and isolated native gates.
- Separate prerequisite-dependent MiMo qualification from ordinary provider tests, retaining required prepared-fixture checks and explicit qualification gaps. Normalize the rollback test's filesystem identity and synchronize the zombie-stream timing test with the initial cancellation.
- Pin the production prompt fixture's EOF format during regeneration; parity still compares the complete corpus bytes and unchanged token/contract expectations.
- Keep documentation freshness stamps date-only, preserving existing dates, immutable source links and historical evidence. Historical source validation reads committed provenance rather than requiring a hash in the stamp.
- Document topic-local changelog updates and conflict resolution that preserves other PRs' entries, keeping release assignment separate from ordinary contributions.

### Cache routing state persistence

- Preserve a write-behind copy of SSD cache holders and observed demand across coordinator restarts while routing reads stay in memory. Restore is bounded by TTL, index caps, clock-skew checks and the cache-key generation; holders bind only to matching live provider capabilities, retaining measured stage-cost deadlines. Disconnects park holders, and shutdown joins provider sockets and the periodic writer before the final bounded flush. No prompts, raw chain hashes or memory-tier holders are persisted.
- Keep revisioned mutations pending until database acknowledgement. One serialized writer snapshots without draining; each successful chunk clears only matching revisions, and failures leave unwritten changes pending. The refactor adds no store schema, wire fields or configuration knobs.
- Durably invalidate validated misses and shorter-hit boundaries even before a holder is restored. For overlapping sessions sharing a durable row, only strictly newer surviving evidence can retain it; otherwise delete the durable copy conservatively while older live holders remain usable until expiry or ordinary invalidation.
- Replace an overflowing holder backlog in O(1), wake the writer and interrupt its batch for a durable reset. Retain a process-lifetime cutoff rejecting older or equal delayed receipts, restored rows and parked rows; reset demand-write deduplication too. A durable marker lets the next boot finish an interrupted reset, but crashes before that marker and concurrent coordinator writers remain limitations.
- `EIGENINFERENCE_CACHE_ROUTING_PERSIST=false` disables persistence. `GET /v1/cache/status` exposes restore and write-behind health under `lifecycle.persistence`; see [counter semantics](docs/reference/api-contracts.md#exact-cache-status) and [restart precautions](docs/operations/cache-routing-rollout.md#persistence-during-restarts).

### Native MiMo V2.6 (Historical Preparation)

- Preserve valid QuickTime PCM tracks in memory-backed audiovisual ingress by pinning the SDK's validated-container URL suffix correction. Input bytes, audio samples, memory ownership and decoder limits are unchanged.
- Keep unrelated resident model slots available when a MiMo owner is retained after a fault. Preserve the MiMo quarantine and process-wide new-load/reclamation fences, and report no cold-load credit while those fences apply.
- Add native `mimo_v2` target and embedded three-head MTP integration with strict source-bound loading, actual native/bridge/consumer ownership and typed retirement. Retain required-fence failures; logical memory settlement is not physical release.
- Add exact native MiMo ordinary dispatch with owned visual/audio policies and bounded encoded ingress. Required sidecars retain separate authenticated ownership. API/media qualification, unsupported formats, speech output and coordinator capability parity remain explicit gates.
- Prepare opt-in text-only COMPLETE-prefix store/loaded-owner integration and bounded performance/residency candidates, preserving native precision, checkpoint topology, fallback paths and memory safeguards. Paging, media-prefix reuse and composed cache/lifecycle qualification remain separate gates.
- Admit exact native MiMo through its dedicated ordinary loader and request its inspected embedded MTP heads by default under `mtp_mode = "auto"`. Preserve explicit `off`, the process-wide kill switch, actual owner/budget/head validation and serial-target verification. Preliminary rectangular MTP measurements include a real greedy-output divergence; that mode remains unqualified and off by default. No catalog publication, deployment or model-limit change is enabled.
- Enable eligible native-rounded MiMo NAX attention and admitted block grouping by default, with process-start rollback controls and memory-budgeted larger solo-text stripes. Preserve explicit overrides, unsupported-device fallback and other model families; candidate runtime qualification remains open.
- Compose explicit serial-MTP paging with authenticated text-prefix restoration and native retirement; retain rectangular and paged-media refusals. These source additions still require full-artifact cache, state and lifecycle qualification.
- Integrate current upstream cache ownership and add separately issued target-only native paging, joint contiguous text-prefix/media ownership, and admitted scalar-shape verification candidates. A selected 114-method component cohort passes; full-model/API, complete MTP state, paging composition and production defaults remain unqualified.
- Resolve linked snapshot directories through the normal scanner without copying weights or changing cache selection order; preserve rejection of invalid and non-directory entries. Explicit revision selections use the same canonical filesystem identity as legacy discovery.

### Deadline projection diagnostics

- Report a closed reason for unbounded provider deadline projections in the existing per-attempt profile. Distinguish scheduler state, cache geometry, capacity guarantees, missing phase rates and invalid duration without changing admission or reconstructing causes for older records.
- Reject SDK-recognized `input_audio` parts for unsupported or unknown architectures with HTTP 400 before model acquisition, prompt rendering or media decoding. Native MiMo dispatch uses provider-owned model metadata and still requires its actual loaded audio profile; generic text/vision paths do not gain audio support.

### Prompt accounting and first-content admission

- Share verified model/template prompt counts across preflight, retries and provider reconciliation while preserving the original deadline, completion limits and billing usage. Match count and cache evidence to the candidate provider's advertised template contract; keep unsupported counts explicitly uncertain.
- Apply qualified prompt-count upper bounds to ordinary deadline forecasts even without a timing profile. These bounds can exceed the previous heuristic, so a tight-budget request previously considered feasible can now be classified as predicted late. Exact tokenizer counts take precedence when available.
- Keep unmeasured prompt-rendering modes outside calibrated fallback estimates, and independently recheck deadline-profile confidence, qualified scheduler limits and cooled applicability in both runtimes before accepting catalog cells. Treat nonempty work reports without original prompt work as unknown.
- Respect cache-planning sampling and throttle denials during count-only fallback, and let retries recover cache/count planning after temporary planning-capacity exhaustion. Ignore malformed advisory prompt-work metadata without dropping an otherwise valid inference request.
- Remove the fixed 50% prefill and decode throughput reduction from coordinator feasibility and provider deadline admission. Use the resolved processing rates directly, preserving original deadline expiry, queued/cache work, count bounds, contention and memory gates. This avoids refusals caused solely by doubling predicted processing time; observed rates remain estimates and do not guarantee on-time delivery.
- Add optional workload-bounded measured deadline calibration with exact MTP identity and ordinary rate fallback for stale, unmatched or incomplete evidence and unqualified runtime overrides. The timing catalog remains empty; removing the fixed rate reduction is active without it. Preserve measured idle/thermal/power prerequisites and posture-bound rate freshness without delaying requests. Correlate whole-Mac work through pre-submit and retirement before pricing contention.
- Add production-path qualification receipts with actual MTP and individual mixed-prefill step timings; profile promotion remains tied to reviewed hardware and held-out prediction evidence.

### Advisory threat-model review

- Restore PR threat-model review through OpenRouter. Scan every changed file with complete before/after text and a cross-file pass against the full threat model. Findings update one advisory comment; incomplete coverage is explicit, clean first scans stay quiet, and model/service failures do not block merging. The workflow executes only the trusted base revision.
- Combine independent Opus 5.5 and GPT-6 Astra full scans through the same OpenRouter key. Attribute findings to their reviewers, preserve differing advice, and retain completed feedback if the other model fails.

### SSD cache write budget

- Raise the default SSD prefix-cache write budget from 150 to 750 GB/day. Explicit environment overrides and unlimited mode remain available.

### Automatic model artifact revisions

- Reject cached or staged revisions with unmanifested integrity files, so an added template, tokenizer or weight file cannot be activated under the original approved hash.

- Return retryable publication errors when alias refresh fails, and accept retained approved hashes during drained model replacement. Retired and unapproved hashes remain rejected.

- Preserve model writer locks across cache removal and refuse removal during an active download or update. Revalidate replacement and rollback snapshots under the activation lease before draining. Keep a first verified download discoverable if the process exits immediately after publishing its snapshot.

- Restore missing or damaged revision receipts only after re-verifying cached bytes, avoiding repeated activation of an already-selected revision. Preserve rollback through valid linked model cache directories.

- Keep a revision's stored download source on `publish-revision` retries, including retries after a committed promotion returns 503. Explicit mirror edits through normal registration remain supported.

- Let each revision declare a different pinned Hugging Face repo, commit and subdirectory through publishing flags or the API, with checksum-verified R2 fallback. Preserve retirement and original upload attribution across registration retries, report failed live refreshes or provider desired-state sends as retryable errors, and retain updates for eligible alias lineage builds.

- Add automatic artifact revisions for existing model IDs: publish immutable R2 bytes and a manifest once, then supporting providers resume/verify downloads, drain accepted requests and activate with rollback. Retain approved older hashes during convergence; add explicit inactive-revision retirement. Share the idle-upgrade lifecycle with Gemma MTP.

### Provider measurements and placement

- Publish prompt-completion observations through coalesced event heartbeats, with sample age/count, workload buckets and cross-model contention. Keep engine decode capacity, delivered streaming and end-to-end throughput separate.
- Add exact reviewed serving profiles, per-engine mixed-prefill policy and a shared whole-Mac service allowance. Show explicit per-model concurrency overrides in status and doctor diagnostics. Unknown profiles retain existing limits; no M5 B8/B16 expansion is certified by this change.
- Size warm pools using actual prompt/generation work and qualified batch curves, keep one model-load planner, retain load hysteresis and use fresh WebSocket RTT in first-content forecasts.
- Extend arrival benchmarks through width 16 and add a qualification receipt evaluator that rejects missing performance, correctness, memory and lifecycle evidence.

### Coordinator first-content routing

- Rank eligible providers by cache-adjusted first-content forecasts by default, prefer credible deadline-feasible choices, and spread near-equal choices by whole-machine service work within a 100-ms band. Preserve physical prompt/output reservations and explicit owner routing.
- Preserve valid prefill observations through 20,000 tokens/s. Track accepted capacity and observed performance freshness separately; missing or stale evidence stays unknown.
- Revalidate reservations and retained alternatives against the original request deadline. After two predictive refusals, require fresh feasible evidence; bound quote fanout to two and launch at most one feasible backup.

### Cached prompt pricing

- Bill prompt tokens a provider serves from its prefix cache at a per-model `cache_read_price` instead of the input price, on the same `cached_tokens` count the consumer receives in `usage.prompt_tokens_details`; a malformed cache report bills at the full input price. Rows without an explicit rate derive half the input price; `cache_read_price` is accepted by `PUT /v1/admin/pricing`, `PUT /v1/pricing` and model registration (`0 ≤ cache_read_price ≤ input_price`).
- Advertise the same rate to OpenRouter as `pricing.input_cache_read` in the provider feed, so a service-account debit equals the feed's per-token math (previously the feed declared `"0"` while cached tokens were billed at the full input price). No cache-write SKU: caching is provider-initiated.
- Publish `cache_read_price` on `GET /v1/pricing`, persist `cached_tokens` on usage rows and `GET /v1/payments/usage`, and surface the rate in the console model catalog and the admin models table. Reservations are unchanged (worst case assumes no cache hit); settlement refunds the discount and emits `billing.cache_read_discount_micro_usd`. The `*_usd` strings returned by `PUT /v1/admin/pricing` and `PUT /v1/pricing` drop the trailing " per 1M tokens" to match `GET /v1/pricing`. Cost arithmetic saturates instead of wrapping on absurd provider-reported counts.
- `/v1/completions` and `/v1/messages` report a validated cache hit in usage, streamed or not: `prompt_tokens_details.cached_tokens` for completions (streams: on the final chunk), and `cache_read_input_tokens` (excluded from `input_tokens`, as Anthropic counts it) for messages (streams: on `message_delta`). The console model catalog resolves an alias's prices from its embedded `/v1/models` pricing, so aliases show input, output and cached-input rates.
- Requests settled against a model-token grant keep pricing every prompt token at the input rate (no cache-read discount on that path) and record `cached_tokens = 0`.
- The coordinator refuses to start if `usage.cached_tokens` or `model_prices.cache_read_price` cannot be added at boot (for example a lock timeout behind a long query on `usage`), instead of booting with price lookups and usage inserts failing.
- On deploy every existing price row — platform and provider custom — starts billing cache hits at half its own input price until an explicit `cache_read_price` is set; the feed's `input_cache_read` moves from `"0"` to that rate.

### Provider readiness diagnostics

- Explain cold model-load memory failures in `darkbloom status`, a color-coded `darkbloom doctor` readiness summary, and the owner My Macs page. The provider reports live no-eviction usable memory and serving headroom separately from the eviction-aware routing capacity; older providers remain compatible and show unknown rather than a guessed verdict.

### Model Download Cache Recovery (Historical Preparation)

- Recover downloads and background prefetch when a model cache entry is a dangling symlink, including links to unavailable external drives. Preserve the original link under a hidden `.models--<id>.unavailable-link-<UUID>` sibling and download into a real directory in the selected cache. Valid directory links and regular files are preserved.
- Align `ProviderCore.version` and the coordinator display fallback at 0.9.12. Publication remains a separate release operation.

## v0.9.11

Published 2026-09-28 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.11)).

### Coordinator legacy-compat cleanup

- `EIGENINFERENCE_MIN_PROVIDER_VERSION` now also excludes providers that report no version from routing. The reference `deploy/environments/prod.env` now says 0.9.5 instead of 0.7.5, but that file changes nothing on the host: the live value in `/etc/d-inference/env` must be raised to at least 0.9.5 by a human, after a fleet-version census, before this coordinator is deployed (`docs/operations/coordinator-deploy.md`). Every registration attestation must carry a fresh timestamp, including from a provider that reports no version.
- The one-shot `backfill_withdrawable_balance_v1`, `backfill_usage_totals_v1` and `backfill_earnings_summary_v1` migrations are retired. Production already ran them. The coordinator now refuses to start on a database whose `balances`, `usage` or `provider_earnings` rows never went through them (or whose `balances` lacks `withdrawable_micro_usd`), naming the missing marker; boot a coordinator built from v0.9.10, which still runs them, once to apply them. An empty database records the markers at first boot.
- Remove the Python-era wire fields: `python_hash`/`runtime_hash` (registration, attestation response, signed status), `hypervisor_active`, and the `python_runtime_locked`/`dangerous_modules_blocked` privacy flags. Providers that still send them keep working. `POST /v1/releases` now rejects `python_hash`/`runtime_hash`; `/v1/runtime/manifest` and `/v1/me` no longer return them.
- Drop compatibility paths for providers below the new floor: the pre-0.6.7 vision penalty strip and the `desired_models` version gate. The tool-call 503 no longer cites a provider version.
- Security: remove the unauthenticated `GET /v1/provider/earnings?wallet=…` lookup, which returned any account's balance and ledger to anyone holding its ID (threat model T-031). It now returns 404; earnings stay available through the authenticated account endpoints.
- Remove the retired `POST /v1/telemetry/events` route (it only ever answered 410); it now returns 404. The coordinator has no client telemetry ingestion and no server-side field allowlist.
- Attestation challenges fail closed: for a provider with an attested key, a missing `status_signature` or an omitted `secure_boot_enabled` fails the challenge instead of being accepted as advisory.
- An `inference_error` without `failure_code` is counted as drift and fails closed as `generation_failure`; status, reason and cause no longer reclassify it, and a bare 429 no longer means queue full.
- App Attest serves protocol 3 only. Registrations announcing protocol 1 or 2 get no shadow frames and are counted as `rollout`/`provider_upgrade_required`; stored enrollments from before protocol 3 never resume.
- `inference_request` no longer carries an empty plaintext `body` object.
- Provider releases trigger only on `vX.Y.Z` tags; the `vX.Y.Z-swift[.N]` alias is gone.

#### Provider

- `provider.toml`: the retired boolean `[backend] mtp` key is ignored with a startup warning. A bare `mtp = true` or `mtp = false` without `mtp_mode` is treated as the `mtp_mode` default, `auto`; to keep MTP off, set `mtp_mode = "off"`. `config_version` is ignored and no longer written, and loading a config never rewrites it (no stamp migration, no coordinator-URL rewrite, no copy from legacy locations). Only `~/.config/darkbloom/provider.toml` or `--config` is read.
- Self-update and `install.sh` install only signed `Darkbloom.app` bundles: flat-only and pre-paged artifacts are refused, and the `eigeninference-enclave` alias is no longer created. `install.sh` no longer migrates `~/.dginf`/`~/.eigeninference`.
- Model downloads fail closed for a catalog entry without a verified manifest (`r2_prefix` + `aggregate_sha256`).
- Removed: `darkbloom-enclave wallet-address`; Rust-era credential, launchd-label and Secure Enclave v1 key fallbacks; the provider's App Attest shadow protocols 1 and 2 (protocol 3 only).
- The bare `runtime-smoke` self-bootstrap for pre-0.8.10 updaters is gone: an updater from 0.7.8–0.8.9 may fail the packaged smoke check (it fails only on hosts where MLX touches Metal early) and then needs an `install.sh` reinstall. Those versions are below the 0.9.5 routing floor anyway.

### Prefix Cache Hit Rate (Historical Preparation)

- Align `ProviderCore.version` and the coordinator display fallback at 0.9.11. The new inference-request field is optional in both directions, so the coordinator and providers can be upgraded in either order; upgrade the coordinator first to keep the 0.9.10 rollout order.

Production ran exact prefix-cache routing at 100% and measured a 1.4–5.2% hit rate per model. See the [analysis](docs/reports/2026-09-26-prefix-cache-hit-rate-analysis.md) and the [rollout procedure](docs/operations/cache-routing-rollout.md). Coordinator and provider changes are independent on the wire: an older provider ignores the new request field, and an older coordinator leaves providers on their previous donation behavior.

#### Provider

- Keep the SSD cache epoch across budget eviction, TTL expiry and corrupt-file removal. Only a whole-root rebuild at load mints a new epoch, so the coordinator no longer forgets a provider's remaining checkpoints each time one file is removed.
- Raise the SSD prefix-cache TTL from 15 to 30 minutes (default equals maximum; the environment override can only shorten it). Recorded as the SEC-035 re-acceptance in the threat model.
- Write a complete checkpoint only on evidence of demand: the coordinator's `cache_repeated_prefix_tokens` at or above the 1,024-token floor, or a prior local sighting. Fleet-novel checkpoints report `skipped_novel` and touch neither disk nor the write budget. The first request for a prefix is served cold and not written, the second is written, the third can hit.
- Capture GPT-OSS 20B and Gemma QAT checkpoints at every 1,024-token boundary regardless of prefill chunk size, including inside a solo stripe, and retain at most three per donor: the first boundary, the boundary at the observed shared-prefix length, and the deepest.
- Report a file that disappeared under a reader as an absent miss rather than corruption; let expiry proceed when a root's only registered store has lost ownership.
- Capture recurrent (Qwen, Nemotron, Bonsai) complete checkpoints at every 256-token-aligned prefill range end, whatever chunk produced it. The uniform-chunk rule disarmed capture when decode company left mid-prompt, so long Qwen prompts published only the boundaries before the first chunk change; measured on real weights, dense Qwen3.5-9B state is bit-identical across chunk partitions and the MoE varies cold already ([report](docs/reports/2026-09-27-qwen-chunk-partition-parity.md)). Files written under the old rule stay valid; adopters resume under ordinary chunking.
- Retain the coordinator's fork target for recurrent donors too: first boundary, deepest boundary at or below `cache_repeated_prefix_tokens`, and the rolling latest, with a fixed 1,024-token adjacency drop for every layout.
- Count recurrent donors whose capture a packed prefill cohort disarmed, once per request, in the heartbeat's `recurrent_capture_disarmed_packed_total` (DogStatsD `provider.prefix_cache.recurrent_capture_disarmed_packed`).
- Enable SSD prefix caching and the paged KV backend by default for the exact catalog ID `Qwen3.5-9B`. Providers reported `config_disabled` for it and served it on contiguous KV under `auto`, so it could not join cache routing; the coordinator's `EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS` tuple for it is a separate operations change.

#### Coordinator

- Prefer a proven cache holder inside the existing 3-second near-tie band instead of collapsing the band whenever a cache credit exists. New selection path `cache_credit` and opportunity reason `selected_near_tie`.
- Bound the proof fence to 60 seconds, doubling per consecutive mismatch to a 10-minute maximum, and drop only the mismatched prompt's holders. Previously a mismatch fenced the capability until the provider's epoch changed and dropped every holder for the model.
- Drop a provider's deeper holders when it proves a hit at a shorter boundary (`shorter_hit`).
- Size the holder index (250,000) and observed-demand index (1,000,000) for a 30-minute window and expire holders from an expiry-ordered heap in bounded passes.
- Forward observed repeat demand to providers as `cache_repeated_prefix_tokens`.

#### Prompt sidecar

- Mirror five provider prompt transformations that caused proof mismatches: tool-call argument key order, integral doubles in arguments, extra keys in tool `function` objects, Harmony channel framing in assistant history, and `output_text` content parts. Prompt-contract IDs are unchanged. Decline to plan for decomposed Unicode object keys and for Harmony control tokens that share a grapheme with a neighbour.

#### Operations

- Rollout procedure for sidecar capacity, plan QPS, holder TTL and the Nemotron Lightning and Bonsai 2 allowlist tuples. The sanitized production env reference now matches the live cache-routing values.

## v0.9.10

Published 2026-09-27 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.10)).

### Live Switching and App Attest Recovery (Historical Preparation)

- Align `ProviderCore.version` and the coordinator display fallback at 0.9.10. Upgrade the coordinator before publishing the separately qualified signed provider; the source bump does not advance the registered latest release.

- Confirm live model-switch success only after a same-session coordinator receipt proves routing resumed with refreshed capacity. Report a missing receipt as unconfirmed. Serialize autoupdate config changes with model-selection writes so toggling updates cannot restore stale hosted models.
- Restore model prefetching before the switch readiness receipt can trigger a refreshed desired-build snapshot. Keep scheduled serving within its original window when model validation and hashing take time.
- Preload selected models on every provider start, regardless of idle-memory policy, including standalone `--local` mode. Coordinator starts remain bounded by the startup timeout; local mode finishes preloading before listening. Slot and memory limits still apply.

- Add explicit model-cache selection through `darkbloom models location`, with interactive confirmation, read-only `--check`, one-time `--from-env` import, and `--reset` to the legacy default. No beta flag, automatic restart, or weight movement.
- Preserve existing providers' cache locations until an operator explicitly saves a path. Ambient Hugging Face/XDG variables never redirect runtime discovery, downloads, hashing, or removal; imported paths stay pinned when the environment changes.
- Preserve filesystem traversal through symlinks and diagnose empty selected caches without mistaking incomplete download folders for models. See the [location command](docs/provider/cli-reference.md#darkbloom-models-location).

- Replace provider reputation ratings with total, successful, and failed job counts. Remove the composite score calculation and owner API field; historical job failures no longer imply reduced routing priority in the dashboard.
- Add `darkbloom switch` to replace the running provider's hosted model selection after a graceful drain, without process restart, coordinator reconnect or re-attestation. Reuse the catalog picker, reject invalid selections as a whole, preserve accepted work on timeout, and persist confirmed selections for launchd restart, watchdog recovery and subsequent scheduled serving windows.
- Live model switching preserves owner-only off-catalog inventory, handles an already-idle `--timeout 0` without skipping coordinator settlement, and lets shutdown preempt read-only weight verification. Switch requests are consumed once across schedule windows; replacement start saves configuration before draining or stopping the current provider.
- Restore the exact prior model-selection config when replacement-start setup fails, without racing other config writers. Carry validation fingerprints with switched model hashes so unchanged cold models avoid redundant hashing; metadata changes and mandatory fresh integrity checks still rehash.
- Keep model-switch routing fenced until the provider reopens local admission and confirms readiness after its commit acknowledgement. Settle queued writer reservations and coalesce overlapping drain barriers without dropping the latest waiter. Refresh desired alias builds after replacement. Live rollback preserves absent selection keys and concurrent settings; missing custom configs use their resolved startup settings rather than another config file.
- Resume model-switch routing only after refreshed serving capacity arrives; retain removed-model queue cleanup through same-session retries. Scheduled windows resolve an empty saved model list as all eligible local models.

#### Public model demand

- Add model demand and fulfillment to Stats, with 24-hour, 7-day and 30-day windows, shared-scale request bars, sorting, expandable outcome counts, per-model timeline charts, an exact interval table, and CSV export. Separate capacity rejections, predicted latency limits, actual timeouts, service errors, client departures and unknown outcomes; HTTP 429 is an overlapping diagnostic.
- Scope new public routing-admission observations explicitly and persist revision-aware hourly aggregates for 31 days. Delay publication by at least one hour and suppress cohorts with fewer than 20 requests or 3 consumer accounts. Label recorded-request coverage and partial collection history; token demand and network-wide completeness claims remain unavailable.
- Preserve compact outcome conflicts and original receipt/model/consumer identity after the detailed diagnostic ledger expires; contradictory replays remain unknown rather than rewriting historical fulfillment counts.
- Count full request queues as capacity rejections and queued first-content deadline expiry as timeouts in public model-demand history, rather than reporting either as unknown.
- Exclude suppressed hourly cohorts from model summaries and all history resolutions so subtraction cannot recover hidden counts. Label counts, percentages, tables and CSV as published observations rather than complete window demand.
- Count provider token/KV/context-budget exhaustion (`unservable_token_budget`) as capacity rejection in public model-demand outcomes.
- Count preflight structural token-budget refusals (`prompt_too_long`) as capacity rejections while preserving validation exclusions. Prune expired model-demand aggregates in bounded transactions, retaining the partial cutoff hour and completed batches when a later batch fails.
- Exclude prompts beyond the model context window from public demand, and count models too large for the advertising fleet and capacity-confirmed dispatch exhaustion as supply rejections.

#### App Attest dead-key recovery and release-recovery fixes

- Retain APNs receipt history through day-long push storms, and keep optional lifecycle diagnostic reads outside proof archival storage admission.

- Preserve explicit update/stall restart provenance through later termination callbacks, and clarify the untrusted diagnostic boundary for consumers and the threat model.
- Keep coarse lifecycle comparisons unknown when ambiguous, reserve report-upload space for diagnostics, finalize idle scheduled shutdown markers, count validated late APNs replies without reauthorization, and fail signing checks on environment mismatch.
- Treat APNs delivery as indeterminate when no push was observed, require actual update-start evidence, and bound diagnostic log reads and parsing memory.
- Keep doctor/report log collection bounded even when termination is ignored; show APNs history on legacy macOS, restrict rotation recovery to the correct account, and distinguish historical push snapshots from current ages.
- Correct App Attest diagnostics for hung security probes, unknown boot security, late APNs tokens, failed WebSocket writes, terminating push loops, full-day key churn, and non-stalled busy replies.

- Replace App Attest keys the Secure Enclave can no longer use. After two consecutive DeviceCheck code-0/2 (or uncoded) assertion failures since the key's last verified assertion, the coordinator asks for a fresh attestation instead of another assertion. Released 0.9.8 and 0.9.9 providers answer by retiring the dead key and enrolling a new one, which must pass the full attestation, receipt, build-qualification and assertion checks. Rotations are durable, limited to one per machine per hour and four per 24 hours (limits carry over when two machine records are merged), controlled by `EIGENINFERENCE_APP_ATTEST_KEY_ROTATION_PERCENT` (default 100), and never revoke or deny serving.
- Serialize App Attest rotation admission with machine merges and resolve stale machine IDs before checking the shared budget, preventing overlapping old/new identities from bypassing rotation limits.
- Back off fresh-key enrollment for 6 hours after a machine's third `invalidKey` attestation failure in 24 hours, instead of generating a new key every few minutes. Reconnects, coordinator restarts and releases do not cut the backoff short.
- Keep retrying the APNs code-identity check on a live connection after the first three pushes go unanswered, at most once per hour through the existing per-device push budget, instead of waiting for a reconnect. Machines that missed the check after a release now recover without a restart.
- Stage the durable Apple device-attestation chain for macOS 27 App Attest candidates too. It attaches only after hardware trust, when it re-verifies to Apple's root and binds this connection's Secure Enclave key; serial restore and serial dedupe stay skipped for candidates.
- Provider: report `launch_session`, `boot_time` and `operation_stalled_seconds` on App Attest `ready` replies (outside the signed transcript). A DeviceCheck call that never answers is reported after 15 minutes and triggers one graceful self-restart when idle, at most every 6 hours, never while a stop or OS shutdown is draining the provider. An attempt that cannot restart does not close admission again on the next check: it waits 15 minutes after an unfinished drain, and 6 hours when its restart marker cannot be saved. `darkbloom doctor` adds an APP ATTEST section with the local key state, launch session and advice for unsupported Macs.

#### App Attest failure diagnostics

- Provider: App Attest `ready` replies add closed, bounded diagnostics outside the signed transcript: process start time, whether the previous run shut down cleanly and why this one started, console-user presence, SIP and sealed-system-volume status, a signing and provisioning-profile check, local key history and APNs push receipt history. Failed attestations and assertions add the native error chain (closed domain buckets and signed 32-bit codes, such as CryptoTokenKit −3 over AKS −536362989). None of it affects authorization; the coordinator drops invalid values without rejecting the message.
- `darkbloom doctor` adds App Attest checks with targeted advice. Local key/history refreshes after every proof, and displayed ages advance between exchanges. Unknown signing or profile checks remain indeterminate instead of passing. Local `devicecheckd` observations are explicitly device-wide, not proof that Darkbloom's key failed.
- `darkbloom report` appends the local App Attest snapshot, APNs push history and closed-pattern, device-wide `devicecheckd` matches, and still uploads when provider logs are empty or unreadable. From a standard account it explains that macOS lets only administrators read the system log. Under `sudo` it reads the invoking user's canonical or legacy credentials without migrating them, plus the user's state file and provider config; an explicit token-path override takes precedence.
- Coordinator: record each APNs code-identity push's outcome (`code_attest.push{outcome}`) and whether the provider answered it (`code_attest.push_reply{result}`), including across reconnects, with no provider, device or token identifiers in metric tags.
- Admin: `/app-attest/diagnostics` breaks the unexplained failure groups down by these fields, classifies dead keys by OS change, reboot or process restart, and summarises rotation outcomes and APNs push receipt.
- Derive reboot/restart diagnostics from provider timestamps in the latest verified assertion context, never by comparing the Mac clock with the coordinator clock; unavailable baselines remain unknown. Rotation recovery follows canonical machine merges when locating replacement proofs.

#### Operations, CI, and community

- Point development GCP defaults and documentation at `darkbloom-dev`; production deployment settings are unchanged.
- Refresh the console's Slack community invite after the previous invite expired.
- Report coordinator and prompt-sidecar coverage in CI job summaries without adding a coverage pass threshold.

## v0.9.9

Published 2026-09-24 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.9)).

### App Attest recovery and snapshot accuracy

- Distinguish signed-app availability failures and synthetic Apple callback/proof errors with closed, privacy-bounded diagnostics. Keep the result and trust policy unchanged; native `NSError` codes remain separate.
- Align `ProviderCore.version` and the coordinator display fallback at 0.9.9. Deploy coordinator and console fixes before publishing the separately qualified signed provider.
- Retire failed or interrupted one-time App Attest enrollment keys instead of retrying them indefinitely. Preserve server-unavailable retries, cached enrollment proofs, accepted assertion credentials, account identity, and persisted generation limits.
- Preserve the original attestation key and hash across server-unavailable retries, reconnects and protocol upgrades, as Apple requires. Later serving assertions remain fresh and bound to the current process endpoint.
- Recover from expired cached-enrollment transactions on a live connection without accepting stale proofs or retrying identity/binding violations. Correct obsolete shadow-only rollout and rollback instructions.
- Accept authenticated macOS CDhash attestation extensions when Apple omits the extension flag; retain complete certificate, nonce, Mac ACL, key, transcript and serving-policy verification.
- Retain bounded Apple error domain/code diagnostics without error descriptions, user-info dictionaries or raw identity data.
- Show public network verification counts and filters at their source snapshot instead of expiring cached App Attest rows into a false zero. Owner serving controls retain live expiry.
- Exclude private-only providers from the unauthenticated attestation roster and its shared cache. Preserve owner access and document public legacy-key linkability and private audit-data destinations.
- Accept fully signed, measured macOS App Attest assertions when Apple omits the extension flag, and recover serving authorization after a fresh, completely archived proof despite an earlier recorded frame refusal. Repair the startup inventory-backfill race only for current authenticated sessions while retaining genuine disconnects and revocations.
- Distinguish an eligible Apple proof from a successfully granted serving lease in App Attest operations, with bounded failure reasons for identity, storage and runtime gates.
- Recognize Apple's signed 20-byte SHA-256 CandidateCDHash only when it uniquely matches the same active, durably qualified signed artifact's full 32-byte CodeDirectory hash; all independent release, receipt, revocation and runtime checks still apply.
- Retry only a completed Apple key-generation callback that returned an error with no usable key ID after a persisted one-minute cooldown, within the normal provider's generation budget. Timeout, cancellation, busy admission, and crash keep the one-hour marker; the budget also bounds possible internally created but inaccessible keys. Retry a definite assertion `serverUnavailable` once with the same key and challenge.
- Recheck a first App Attest grant after one, five and ten minutes while Apple risk-receipt renewal is still unverified; a fresh assertion, verified risk metric and every existing serving check remain required. macOS 27 alone never grants authorization.
- Reprobe a live connection's generic or server-unavailable Apple App Attest failure after one, five, then every ten minutes instead of leaving its accepted key idle for an hour. Storage failures retain their slower backoff; signed policy failures remain terminal.

## v0.9.8

Published 2026-09-22 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.8)).

### Graceful lifecycle and App Attest recovery

- Align `ProviderCore.version` and the coordinator's `LatestProviderVersion` fallback at 0.9.8. Deploy coordinator drain-barrier support before publishing this provider; qualify the exact signed artifact independently before advancing the registered release.

- Extend graceful draining to replacement starts, standalone/foreground handoffs, manual update activation, and planned APNs/model-inventory reconnects. Background update deadlines defer without force-cancelling work; failed pre-publication setup restores recovery, and restart recognizes explicit owner self-route authorization.

- Drain accepted inference and local response writes before normal provider stop/restart, confirm terminal usage with the coordinator, preserve model selection, and report recoverable timeouts separately from explicit force.

- Replace the static landing page with the Darkbloom Next.js site from eigen-homepages, preserving the old legal URLs with redirects.
- Recognize the 2026 M6 and M5 Pro Mac minis and M5 Max Mac Studio for base-reward memory caps and complete the new desktops' earnings-calculator choices. Recognize M5 Ultra for serving bandwidth while withholding its disputed identifier from base rewards. Report M6 as its own chip family with conservative MTP and model-capability gates pending physical qualification.
- Retry generic Apple App Attest API failures with the existing bounded backoff instead of leaving a live connection permanently pending. Failed exchanges remain unqualified; fresh proof and all serving-policy checks are still required.
- Retry a first verified App Attest assertion early while Apple's risk receipt is pending. A successful receipt still requires a fresh assertion, machine identity, build qualification, and all serving-policy checks; missing risk evidence never grants serving.
- Keep the interactive `darkbloom unenroll` administrator profile inventory in the foreground terminal group so `sudo` can hide password input and complete the read. Background jobs, denied authentication and noninteractive reads withhold removal guidance without changing profiles or authorization.
- **Privacy descriptions** — Describe encrypted network hops and plaintext processing at the coordinator and provider, distinguish qualified MDM-optional App Attest authorization from legacy MDA evidence, and remove unsupported memory-wiping and recipient-key forward-secrecy guarantees.
- Unify App Attest and legacy verification labels, dispatch-time chat proof summaries, live authorization expiry, and network method counts without changing legacy trust fields or exposing private Apple evidence. Keep owner lease fields and geography counts on the same live authorization snapshot, and label unsupported App Attest protocol versions accurately.
- Operations helpers encode admin JSON fields, return a failure after any fleet host fails while still visiting remaining hosts, and isolate smoke-test response files.
- **Admin email login** — Encode Privy OTP email/code fields as JSON strings so quoted addresses and escape characters cannot break or reshape the upstream request.
- Preserve Responses `instructions` as a leading system message in serving and prompt-cache preparation, and include them in admission/billing estimates. Retain inline media and tool history; reject invalid instruction types.
- Route forced media tools and media-bearing tool results only to providers advertising the model's native capability; preserve aliases, queued/retried requests and legacy refusals. Native DiffusionGemma retains tool-result assets in actual call order without changing its sampler.
- Reject malformed or negative top-level output-token budgets before coordinator defaulting and admission on all inference endpoints; preserve omitted, null, zero and valid positive budget behavior.
- Preserve ordered inline image/video content and media-bearing tool results when lowering Responses requests for inference. Retain vision admission and inline-only Responses URL policy; media remains ineligible for the separate text-only prompt-cache planner.

- Add an opt-in native DiffusionGemma sampler candidate preserving exact RNG constants, request-local key order and validated state commits, with original-path fallbacks and benchmark-only dispatch evidence.
- Add an opt-in native DiffusionGemma soft-conditioning projection candidate using the existing affine matrix arithmetic and unchanged weights, with original training/transform/stream fallbacks and benchmark-only dispatch evidence.
- Add opt-in DiffusionGemma benchmark route observations, separating first-iteration dispatch evidence from disarmed timing iterations without changing serving controls or generation.
- Add native DiffusionGemma committed-block serving and image/video-frame discovery, including multimodal template validation. Keep text-only declarations disabled for media and preserve existing load and memory safeguards; catalog publication and release qualification remain separate.
- Preserve DiffusionGemma's native tokenizer whitespace default without rewriting artifact metadata or changing other processors; explicit cleanup settings remain authoritative.
- Fail unexpected nonempty DiffusionGemma reasoning before exposing it when thinking is disabled, while preserving empty native envelopes and never promoting tool examples from an unclosed thought.
- Avoid restoring the sorted expert-output intermediate on eligible native DiffusionGemma inference paths. Preserve the existing weighted-reduction order, model weights and denoising controls; retain legacy training, shape, precision and stream paths plus an explicit rollback.

- Persist independently approved App Attest builds and revocations; refresh qualification without per-release coordinator restarts, with bounded failure/expiry and stale-grant fencing.
- Stage immutable signed provider artifacts before publication. Block unqualified releases before updater/latest aliases advance; retry the separate publication job using the same signed bytes, without rebuilding or notarizing again.

## v0.9.7

Published 2026-09-20 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.7)).

### MDM-optional providers and account-scoped SLAs

- Align `ProviderCore.version` and the coordinator's `LatestProviderVersion` fallback at 0.9.7. Publication, coordinator deployment and App Attest serving/removal activation remain separate rollout steps.

#### Model verification I/O

- Enable reusable-buffer reads and up to four independent file readers by default for model integrity verification, preserving complete SHA digests, failure handling and load-time checks. Explicit overrides retain the original reader and serial hashing for rollback.
- Pin MLX Swift and MLX Swift LM to their merged Bonsai constant-reuse, carry-scheduling and HTTP-validation updates. Preserve the existing MLX core/C pins and native Qwen4 support.

#### Bonsai performance and API stability

- Enable encrypted SSD prefix-cache eligibility by default for the three exact supported Bonsai 2 MLX identities. Preserve the global cache opt-out, fresh load hashes and runtime capability/identity gates; resident RAM retention stays opt-in. Signed persistent-restart qualification and coordinator artifact allowlisting remain separate rollout steps.

- Complete late local Chat/Completions failures with a sanitized SSE error event instead of truncating the HTTP body. Preserve cancellation, pre-header errors and the direct SDK throwing contract; this does not change model generation or turn failed tool calls into successes.

- Enable qualified earlier compact-carry submission and exact FP16-to-FP32 constant reuse by default on eligible Bonsai paths. Unset and exact `1` enable each path; explicit `0` restores its prior behavior and other explicit spellings remain disabled. Keep all shape/dtype/fault gates, generic cache rollback, published weights, native precision, architecture, context limits and absent-MTP capability unchanged.
- Record matched M3 Ultra/M5 Max prefill, decode and memory measurements, including prefill tradeoffs and the real retained-constant cost. Dependency review, post-merge repinning and deployment remain separate actions; this performance draft is not a release.
- Qualify early provider-local rejection of negative output-token limits through the SDK service, preserving explicit zero and valid requests. Coordinator validation and model numerics are unchanged.
- Preserve the fixed SDK input-validation error through local chat interception, and explicitly admit the qualified Bonsai XML family to nested-reasoning routing for both text and media. Preserve opaque argument bytes and existing other-family policies; do not guess string unescaping.

#### Account-scoped first-content SLA

- Apply the first-content SLA only to authenticated accounts selected by `EIGENINFERENCE_FIRST_CONTENT_SLA_ACCOUNTS`; configure the intended account privately in the deployment environment. Direct users and other service accounts have no first-content timeout, including no 600-second fallback; queue limits, client cancellation and post-content response timers remain.
- Preserve configurable model timing for selected accounts, including Bonsai’s 9s + 5ms/token coordinator cutoff, and support explicit public-model policies before alias resolution.

#### MDM-optional provider authorization

- Warn on stderr for every CLI invocation below macOS 27, including help/version, while preserving commands and JSON output. Add prominent setup/dashboard upgrade notices, distinguish older from unknown reported OS versions, and retain legacy service during the transition.
- Show current App Attest authorization on the owner dashboard without demanding legacy MDM verification; expire cached grants locally if polling fails and preserve independent legacy proof fields.

- Retry first-proof App Attest readiness outages with a bounded early assertion retry (one minute, then five minutes, capped at the normal ten-minute cadence); recheck the complete proof, identity and serving policy after recovery.

- Reflect App Attest revocation in untrusted status, availability and fleet counts without duplicate decrements or legacy-challenge recovery. Require a coordinator decision received within 10 seconds before offering MDM removal, even when the daemon keeps rewriting its state file.

- Skip new MDM enrollment in the installer and CLI on macOS 27 or later; guide users through App Attest approval. Explain that upgrading avoids MDM and Darkbloom MDM will be deactivated soon. Keep existing profiles and coordinator authorization/removal gates intact; pending App Attest never falls back to automatic MDM enrollment.

- Fence successful admin revocations even when the request deadline expires, and fence freshly verified revoked credentials before their first serving grant. Preserve bounded leases/refresh records through unknown readiness results without extending authorization.
- Preserve legacy identity/MDA recovery for providers outside the authenticated rollout cohort and on older macOS. Restore a previously missing historical baseline after a later canonical merge without double-counting live work.
- Count only authorized inference handoffs as provider dispatches; rejected frames clear provisional timing, and cancellation while waiting for authorization preserves the healthy connection.
- Commit pending base-reward allocations atomically and reallocate after a late authorization/identity rejection, preserving prior finalized payments and pool/account caps. Resolve same-account endpoint continuity while session inventory catches up.

- Consolidate App Attest session, archive, receipt, inventory and authorization workers under `coordinator/appattest/service`, with their unit tests. Keep only API wiring/authentication/release adapters; retain storage and scheduler locking with their owning packages.

- Make plain `darkbloom unenroll` offer full exit or App Attest migration, with an explicit macOS 27+ requirement and fresh coordinator approval for migration. Cancel/EOF makes no changes; full exit stops the provider service before optional cleanup, and the cleanup prompt explicitly lists Secure Enclave signing keys.

- Add independently enabled App Attest serving alongside complete legacy MDM/MDA and APNs verification. Require qualified signed code, current encrypted-endpoint assertions, durable evidence, valid receipts and fresh revocation state; preserve legacy trust flags.
- Fence every new inference handoff on expiry, revocation, connection/endpoint replacement and policy changes, including queued requests and retries. Durable revocation refresh has a bounded lifetime; database failures cannot extend permission.
- Preserve verified canonical machine history across reconnects and credential rotation, without allowing a claimed serial to evict another provider. Extend base rewards to qualified App Attest-only machines with canonical duplicate/epoch settlement protection and preserved historical balances.
- Add coordinator-derived authorization diagnostics and `darkbloom unenroll --keep-serving`. Require fresh removal readiness, preserve local identity/account data and identify only Darkbloom's enrollment profile before guiding the user through System Settings; company management is retained.
- Keep serving/removal disabled by default and retain explicit signed-artifact/security-transition qualification before activation. DeviceCheck's separate two-bit API is not required.

### Model token promotions

- List Bonsai first in the chat model dropdown. Show its “Free” badge only after a confirmed claim for that exact model with available tokens; hide it while grant status is unknown, on lookup errors, or when the allowance is exhausted or fully reserved.

- Enable thinking by default in frontend chat requests.

- Configure one-time, model-specific token grants before registration. Eligible users explicitly claim non-expiring tokens shared across their account keys, with an atomic campaign cap and signup cutoff. Prepare the Bonsai draft for 250 claims through September 19 by accounts created through September 18 (Los Angeles time). Exhaustion falls back to paid credit, with clear console allowance/error states.
- Reserve and settle free tokens, paid credit and provider earnings atomically; retain platform-priced provider payouts on sponsored traffic, protect same-account serving, and recover orphaned reservations.
- Recover usage, key spend and fee accounting after promotion settlement retries; release holds after deterministic failures and reject zero-token payouts.
- Bound sponsored provider earnings to exact token prices, carrying fractional micro-dollars atomically instead of funding a minimum payout for each tiny request.
- Give Bonsai 2 a 10-second plus 5-ms-per-input-token upstream first-content SLA, retaining coordinator response headroom. Add exact-model overrides for both SLA terms.

## v0.9.6

Published 2026-09-18 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.6)).

### Ternary Bonsai 2 onboarding draft

- Compact Bonsai's retained recurrent convolution carry after prefill, preserving exact FP32 state bits without retaining whole chunk buffers. Other model families and single-token decode are unchanged.
- Apply the existing serving allocator guard before throughput-sweep model loading; bound freed-buffer retention and report active/cache memory separately without changing model precision or KV limits.
- Add the `prism_hadamard_qwen35` native CBv2 adapter for the unchanged Prism Bonsai 2 27B affine 2-bit pack, including its real vision tower and explicit absence of MTP heads. Preserve signed-Hadamard transforms, FP16 packing, paging safeguards and matching provider/coordinator prompt semantics. Register `hadamard.json` as an integrity-bound config asset. Qualification and catalog/release activation are separate; this draft does not deploy the model.

### Flash-Next Signed-App Resource Recovery (Historical Preparation)

- Wait for the SSD write-behind consumer task to finish when draining after shutdown, so the final payload is released before teardown completes. Preserve reusable drains while the pipeline is running; cover the shutdown handoff with 10,000 regression cycles and both SDK 27 CI lanes.
- Resolve native Qwen Metal preambles from the signed app’s `Contents/Resources`, including installer symlinks; prevent developer build paths from hiding missing packaged files. Model weights and kernel bytes are unchanged.
- Exercise all Qwen Metal preambles in `runtime-smoke` before signing, after notarization, and through the existing installer/updater smoke. Add relocated-app, missing-resource, symlink-escape, and standalone-development regression checks.
- Require provider 0.9.6 or newer for `qwen3.8-flash-next`, excluding the crashing 0.9.5 bundle without changing other models. Keep the 262144-token native context and memory safeguards. Cold SSD-offload accounting requires the separately deployed coordinator.

## v0.9.5

Published 2026-09-17 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.5)).

### Qwen 3.8 Next/native Qwen4 follow-up

- Recognize the exact `qwen3.8-flash-next` registry ID alongside the legacy developer ID for native Qwen4 media, paging/prefix, tool and reasoning policies. Keep artifact/configuration checks and developer-only path overrides intact.
- Use native model context in listing and runtime policy, with a 262144 fallback only for the known artifact identities. Remove the extra 82K bridge clamp; retain lower-only operator overrides, checked prompt-plus-output budgets, physical-memory safeguards and coordinator SLA admission.
- Mirror the registry-ID prompt semantics in Rust and bump the shared Swift/Go/Rust normalization contract to v6. Old contracts fail cold rather than receiving cache credit under different semantics.
- Gate the registry ID on provider 0.9.5 or newer across request shapes; legacy and other models keep existing version floors. Align the provider version and coordinator display fallback without retagging 0.9.5 or deploying this draft.
- Leave SDK, model weights, quantization, embedded MTP and numerical kernels unchanged. Physical full-context and composed API qualification remain separate from policy-level tests.

#### Release reliability and build reuse

- Make model-free Qwen4 standalone admission tests use controlled memory, including
  low-headroom refusal and recovery, while retaining production memory safeguards.
- Run optimized SDK 27 compilation alongside SDK 27 prompt parity and tests; gate
  signing on both and verify the source-bound unsigned artifact before signing.
- Warm compatible Swift, Rust and Metal caches on master for release tags, preserve
  unchanged source timestamps, and report cache reuse without skipping validation.


- Pin the native Qwen4 SDK to merged upstream PR #149. The approved SDK source tree is unchanged; this dependency update introduces no new model, numerical or performance changes.
- Stage native Qwen4's bounded MTP catch-up, consistent carry-only initialization of cold/restored unprimed heads and grouped selected-page KV reads as a paired SDK/provider default candidate. Preserve already-primed caches, target parameters, ordered attention arithmetic and explicit rollback controls; full default-posture qualification is required before promotion.
- Derive eligible Qwen4 SSD-offload load estimates from validated native copy bounds instead of generic 20% padding. Preserve all compute/MTP/vision payloads and the existing OS, activation and KV safeguards; other layouts retain their previous policy. Recheck actual headroom for at most two seconds after owned Qwen4 retirement, without granting speculative reclaim credit. Physical full-model qualification remains required.
- Discover hidden SwiftPM resource bundles during paged-backend preflight while retaining sealed-app boundaries and rejection of conflicting source bytes. No model arithmetic or weights change.
- Preserve reasoning with its following function calls when the standalone Responses API replays prior output as input. Keep explicit message/tool-result boundaries, argument bytes and media unchanged; no model, MTP, sampling or cache-algorithm change.
- Preserve both upstream Hugging Face mock isolation and the Qwen native-GPU test gates when composing the provider CI runner.
- Snapshot verified converter metadata before shard conversion so later license, tokenizer or template mutations cannot enter a successful pinned conversion.
- Preserve all semantic Qwen4 configuration fields across Codable round-trips. Bind and validate PLE resources in both model factories, keep legacy request state in each cache, and reject unsupported generic generation recoverably.
- Run the ordinary Qwen4 benchmark through native CBv2, with normal EOS handling, explicit target-only/cache-off scope and complete duration accounting. Preserve other models' JSON5 configuration support.
- Materialize Qwen4 fused expert weights through the existing bounded loader hook after relinquishing staging owners. Retain explicit physical-memory, reload and deadline qualification gates.
- Keep unsupported generic SDK sampling controls explicit without changing native provider support. Align the provider version and coordinator display fallback at 0.9.5; publication and rollout remain separate approvals.
- Enable the existing Qwen4 full-KV parallel attention, 32 value partitions and early layer submission by default for eligible decode/MTP verification. Preserve explicit `0` rollback, compact-KV opt-in, wider-prefill fallbacks and unchanged model weights, arithmetic and MTP policy.

### App Attest and Console Follow-ups

- Forward the latest distinct per-model warm-pool planning snapshot through the coordinator telemetry emitter so Datadog can show target sizing, measured demand, candidate availability and blocker counts. Keep provider identities and request data out of the event.

- Stop minting an unrestricted console API key after you create a My Machine only key. Chat adopts the key you just created; `POST /v1/auth/keys` inherits `self_route_only` when every active key on the account is already machine-only. Logout, chat 401, and untracked mint drop a leftover console key id so a stale id cannot pin chat to the untitled secret.

### Combined Streaming Usage

- **Combined streaming usage** — Preserve validated cached-token and reasoning-token details when a Chat stream carries usage on its finish event. When a dedicated usage event follows, enrich only that event; do not duplicate details, invent usage, or change content, token totals, signatures or terminal identity.

### Qwen 3.8 Next (Flash-Next) Support (Historical Preparation)

- Record the human-reviewed candidate and final 118-cell local API pass,
  account-scoped cache/usage fixes, default long-prefix cache qualification,
  full affected-suite results and matched speed checks in the
  [native API/cache qualification report](docs/reports/2026-09-15-qwen38-native-api-qualification.md).
  Existing opt-in multirow and semantic-quality limitations remain explicit.

- Align final non-streaming reasoning-item status with streaming Responses;
  preserve the root incomplete/complete status, original text, usage and
  provider attestation fields.
- Preserve the Chat stream's response ID and creation timestamp on terminal
  coordinator metadata while retaining signature/hash values and the distinct
  job ID. Include `input_tokens + output_tokens` as Responses `total_tokens`;
  cached/reasoning details are not counted again and billing is unchanged.
- Add a real-coordinator/native-unified API matrix with authenticated metrics
  from the same provider. Replace the generic plaintext test's ASCII-density
  heuristic with an exact known-answer/UTF-8 check, preserving normal surrounding
  whitespace without rewriting engine output.
- Require a declared native function header or framed JSON at each forced-tool
  frame opening. Reject prose in that header boundary while preserving literal
  argument content and mandatory final validation; no output repair is added.
- Preserve original messages for exact owned native Qwen4 text required/named
  calls through Swift serving/accounting and the Rust prompt sidecar. Advance
  normalization to v5; previous identities fail cold for exact-cache credit.
- Preserve per-request rotary position semantics in mixed text/image batches,
  including hidden-returning MTP history paths. Keep singleton admission and
  speculative caps unchanged; longer-prefix batching qualification remains open.
- Add qualified opt-in full-KV parallel attention and early layer submission,
  plus canonical media-prefix positions for appended-text reuse. Preserve
  native state, PLE fill/fault ownership, MTP and existing fallback behavior.
- Require native tool framing after the rendered reasoning boundary for
  required/named Qwen4 text calls. Keep argument values model-generated and
  retain strict postvalidation and target-only constraint safety gates.
- Record bounded speed gains and unresolved quality/release gates in the
  [September 15 draft update](docs/reports/2026-09-15-qwen38-performance-stability.md).
- Mirror parallel-aware required/named tool instructions for other paths in
  the coordinator's prompt sidecar. Regenerate immutable prompt vectors and
  preserve ordinary serving across mixed prompt-contract versions.
- Preserve non-reasoning Qwen 3.8 Next function-call history on the standalone
  Responses endpoint and emit Responses SSE lifecycle/item events, including
  incomplete and failed terminals. Add actual cold-load admission regressions
  covering the Nemotron standalone-guard lesson.
- Drain native completion before the final empty-pool memory refund; retain
  strict allocator and scoped-stream ordering tests.
- Reject unsupported thinking efforts for the owned Next artifact with a
  typed HTTP 400 before template rendering. Preserve native low/medium/xhigh
  controls, disabled-thinking precedence and other models' templates.
- Make required/named tool instructions respect allowed parallel calls. Retain
  the singular contract when parallel calls are disabled; do not contradict
  a request for several independent calls with singular forcing instructions.

No provider version bump, model publication, catalog activation, release or
deployment is implied by this support update.

- Add native Qwen4 text serving with retained embedded MTP, SSD-backed learned
  PLE tables, native paged state and complete-checkpoint support. Scope automatic
  paging/cache defaults to the exact owned serving identity; preserve artifact,
  runtime, dtype and cache-identity gates.
- Enforce a lower-only local context limit over prompt plus reserved completion,
  reject overflow with a sanitized client error, keep unsupported media out of
  the text path and preserve request-owned cache usage and connection cancellation.
- Carry validated SSD-offloaded weight declarations through provider/coordinator
  admission and add repository-owned pinned conversion/provenance tooling.
- Record current component/synthetic checks and remaining fresh-build, real-model,
  cache/restart, API and hardware qualification in the
  [native support reference](docs/reference/qwen4-next-support.md).
  Full production qualification remains separate from the reviewed support update.

## v0.9.4

Published 2026-09-15 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.4)).

### App Attest Recovery and Retirement Readiness (Historical Preparation)

- Fix the released 0.9.3 App Attest callback-timer abort. Require the callback completion/expiry smoke in the optimized signed bundle, installer and updater; distinguish callback failures from Metal failures.
- Keep App Attest off by default, require an explicit stable account cohort and provider 0.9.4 or newer. Existing APNs/MDM serving and the supported macOS floor remain unchanged. Production App Attest remains paused until a separately approved rollout.
- Retry transient shadow failures, including temporarily saturated control-lane sends, without disconnecting serving providers; bound actual uncancellable Apple operations and fence late callbacks.
- Recover cached enrollment receipts through a separately validated renewal path, retain original failure records, and reconcile interrupted evidence without advancing counters. Receipt renewal requires the dedicated server credentials.
- Associate machine identities through fresh account-bound App Attest assertions, including reconnects after legacy-key rotation. This does not rewrite balances or certify physical-device uniqueness.
- Negotiate App Attest protocol 3 to bind app-measured machine model, RAM, CPU/GPU counts and the existing verification key to the signed transcript. Preserve old transcripts and cached enrollment recovery across upgrades; move the unchanged base-reward memory-cap catalog out of the MDM package.
- Record versioned prospective authorization outcomes, revocation, current-connection freshness, qualified builds and receipt/risk readiness. The private dashboard shows exact cohort denominators and blockers for a later MDM retirement.
- Capture SDK 27 Apple-signed CodeDirectory measurements and require an exact qualified binary/code-hash pair for prospective build approval. Release builds and their provider tests select SDK 27 / Swift 6.4 and record the full CodeDirectory SHA-256; missing or unsupported measurements stay unknown. macOS can identify the exact code without a bundle-version extension.

## v0.9.3

Published 2026-09-15 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.3)).

### App Attest shadow rollout and provider reliability

Source changes since `v0.9.2`. App Attest remains observational, with APNs and MDM authoritative.

#### Prefix-cache reuse and routing

Provider changes require a new signed bundle; coordinator changes require a
coordinator deployment.

##### Provider

- **Checkpoint write priority** — Limit first-seen checkpoint writes to a continuously refilling 90% share of the existing write budget, reserving capacity for prefixes observed again within the cache TTL. Every write still consumes the original total budget; authenticated durable duplicates consume no additional write budget. Novel-share exhaustion reports `write_priority_limited`, while total-budget exhaustion remains `write_rate_limited`. TTL, disk-space reserves and the overall write cap remain unchanged.
- **Maintenance recovery** — Reconcile removed checkpoint index entries inside the destructive epoch barrier for whole-root external mutations so later reconciliation does not rotate the model epoch again solely for those removed entries. Single-entry eviction and corrupt-file removal update only their known index entries, avoiding a full filesystem scan after each victim during budget reduction. Surviving valid checkpoints remain reusable.

##### Coordinator

- **Qwen prompt parity** — Match the provider's Qwen-family handling of required and named tool calls, including catalog aliases and Qwen3-VL, to avoid mismatched thinking controls in cache proofs.
- **Repeated-prefix routing** — Prefer a stable cache-capable provider for repeated prefixes only among otherwise equivalent cost, queue and pending-work candidates. Exclude capabilities quarantined after a failed cache proof from this preference, even when heartbeats continue advertising them. Revalidate at reservation and rescan if affinity eligibility changed after selection. Preserve ordinary serving when no unfenced cache candidate is available, along with capacity, deadline, trust and proof gates. Profiler rows identify this preference as `prefix_affinity`.
- **Cache opportunity diagnostics** — Report per-model reasons and numerical counts for repeated-prefix demand, usable holders and routing selection. These diagnostics distinguish routing opportunities from actual cache hits and measured latency savings. Add a [consumer guide](docs/consumer/prefix-cache.md) for preserving shared prompt prefixes.

#### Doctor and attestation reliability

- Prevent large process lists from blocking `doctor` and `verify`. Capture contention and sleep-probe output without pipe backpressure and apply an execution deadline; preserve diagnostic output and failure handling.
- Match the coordinator's canonical status bytes for mixed-case model IDs and template names, including Unicode separators. Preserve signed fields, omission rules and signature verification.

#### App Attest coexistence

- Add stable server-assigned machine identities, verified legacy aliases, historical backfill and macOS adoption inventory. Keep existing operational serial, routing, and accounting rules.
- Retain complete attestation and assertion submissions, initial and renewed receipts, verification context and outcomes in a private durable archive. Add an authenticated admin dashboard and complete-record downloads.
- Bind account scope and locally derived OS/build status with protocol 2. Recover lost enrollment responses, cap key generation across accounts, and bound Apple callback waits. DeviceCheck's separate device-bit service stays deferred.
- Bound shadow archive, rejection, and disconnect work against the shared database pool; count saturation as a coverage gap. Recover after missing Apple callbacks without restarting the provider. Continue renewing existing receipts when new shadow exchanges are disabled.
- Repair missed inventory disconnect records from durable liveness history after contention or restart. Use only bounded, validated endpoint keys for shadow enrollment, and label original-field and decoded-proof checksums explicitly.
- Include App Attest frames rejected by the 48 KiB decoder limit in refusal telemetry and the machine-inventory census, without retaining oversized proof payloads or blocking normal provider messages.

- Add negotiated App Attest shadow enrollment and fresh connection assertions, with independent certificate/policy verification, durable counters, and coverage/latency observations. APNs and MDM remain authoritative; shadow success or failure changes no routing, trust, payments, or supported OS floor.
- Keep the CLI and app launch flow; add profile-authorized App Attest signing alongside APNs in release and validation workflows. Actual macOS 27 acceptance requires the final signed app on physical hardware.
- Accept macOS Developer ID profiles granting only the App Attest CDhash opt-in, including array grants. Preserve existing APNs/keychain entitlements; validate the attested environment on the coordinator even when the optional environment entitlement is absent.

### GPT-OSS SSD Caching

- **GPT-OSS 20B SSD prefix caching** — Enable authenticated complete paged checkpoints by default for exact `gpt-oss-20b`. Restore native full-attention rows and sliding-window state under the existing tenant, model, prompt and runtime identity gates. Keep resident retention opt-in; global cache disable and contiguous fallback serve cold. Other GPT-OSS IDs remain opt-in.

## v0.9.2

Published 2026-09-11 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.2)).

### Gemma QAT Caching, Adaptive MTP and Nemotron Lightning (Historical Preparation)

Source changes since `v0.9.1`. Provider changes require a new signed bundle.
The provider wire protocol remains compatible with the 0.9.1 coordinator;
coordinator and console changes below require their own deployments. The
[rollout review](docs/reports/2026-09-10-provider-092-rollout-review.md) records
compatibility checks and outstanding runtime qualification.

#### Provider

- **Gemma QAT SSD prefix caching** — Enable authenticated complete paged checkpoints by default for exact `gemma-4-26b-qat-4bit`. Preserve tenant, model, prompt, binary, metallib and numerical-state identity checks, the global cache disable and cold fallback. Other Gemma artifacts remain opt-in. A new binary starts a new checkpoint identity; existing 0.9.1 checkpoints are not reused across the upgrade.
- **Adaptive Gemma MTP** — Automatically resolve the catalog assistant for that exact QAT target and select ordinary decode or one draft token from measured committed output and elapsed time. Include seed work, reset workload learning when requests finish or IDs are reused, and track compilation warmup by exact verification shape. Support target-prefix sampling for temperature/top-p/top-k/min-p, with ordinary decode for unsupported transforms and explicit diagnostic verification controls retained.
- **Assistant activation while serving** — Download and verify the optional assistant while the current engine serves. Reserve staging memory and retain its target against eviction; publish reduced capacity immediately and restore survivor KV grants after discarded preparation. After network rollout jitter, close only that model's new admissions, advertise `reloading`, and finish accepted work before swapping. Racing requests receive transient 503 `slot_state` refusals. Timeout or cancellation discards the candidate and reopens the original engine without cancelling accepted requests. Standalone follows the same bounded drain without fleet jitter; insufficient memory preserves target-only serving.
- **Assistant download sources** — Honor catalog-declared immutable Hugging Face assistant revisions with checksum-verified R2 fallback and jittered fetch retries. Existing R2-only metadata remains valid; shipping this binary does not apply the separate catalog patch. Standalone uses its configured coordinator catalog authority.
- **Nemotron Lightning serving** — Admit the three explicitly qualified registry/Hugging Face IDs on the existing network and standalone paths; reject other `nemotron_h` artifacts. Enable native paged KV and complete encrypted prefix reuse with native activation/KV precision and FP32 persistent Mamba state. Declared embedded MTP uses request-owned assistant state, exact prefix checkpoints and adaptive depth up to seven; checkpoints include Nemotron numerical controls.
- **Native reasoning and tools** — Separate Nemotron reasoning before tool parsing and validate required/named calls before publishing them through the existing encrypted response stream. Keep Gemma grammar enforcement and explicit per-model capability advertisement. Fix standalone Lightning admission to use the model's exact identity before the existing memory gate.
- **Shared inference dependencies** — Pin the merged MLX core, C, Swift and SDK chain for explicit mutable Metal-kernel inputs, request-owned paged MTP, recurrent rollback, checkpoint ownership and typed native generation events. Release CI includes nonzero/no-skip synthetic SDK gates; real-model gates remain separately identified.

#### Companion coordinator and console changes

- **Warm-pool headroom** — Grow warm replicas from measured headroom before a failed request, using measured occupancy growth, per-model headroom limits and bounded load bursts. Requires a coordinator deployment; the provider release does not activate this policy.
- **Earnings navigation** — Keep earnings accessible after removing all linked Macs and display the supported payout-coverage notice. Requires a console deployment.

#### Qualification and rollout

The reviewed source has passing component and integration evidence, but final
combined-artifact model qualification remains incomplete. The amended Gemma
admission-drain path still needs matched B1 on/off, B4 branched-prefix and real
HTTP activation/download-failure checks. Earlier greedy MTP coding outputs
show a repeated source-ID correctness defect absent from the ordinary-decode
controls on that prompt; no general answer-quality equivalence or cache
corruption conclusion is claimed. Published-chain Nemotron connected-serving
and restart qualification also remain open. See the rollout review before
fleet publication; source compatibility alone is not a release-ready verdict.

## v0.9.1

Published 2026-09-09 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.1)).

### Cache reliability and recovery

Source changes since `v0.9.0`. Provider changes require a new signed bundle;
coordinator and console changes require their own deployments.

#### Provider

- **Request completion during recovery** — Keep completion/error delivery working after cache shutdown or deallocation, deliver each terminal once, and drain accepted cache evidence before its terminal. Preserve secondary-tier terminal suppression.
- **Duplicate checkpoint reuse** — Keep an existing complete checkpoint when another request reaches the same prefix with a different valid prefill chunk size. Reauthenticate its original bytes, metadata and complete encrypted payload; preserve identity, tenant, state-layout and corruption checks.
- **Checkpoint write recovery** — Preserve unrelated valid checkpoints when atomic creation of a new checkpoint fails, allowing a later donation to retry without an unnecessary cache-epoch reset. Existing files that fail reauthentication still revoke their cache evidence.
- **SSD disk budget** — Size the shared cache at half of currently available disk space without a fixed 100 GiB ceiling. Keep a fixed 20 GiB low-disk write reserve instead of 5% of the whole disk, and check the full pending donation against space above the reserve. Preserve encryption, eviction, daily write limits and ENOSPC handling.
- **Cache failure attribution** — Distinguish complete-checkpoint host-memory, epoch, maintenance, disk-space, unsafe-path, I/O and eviction outcomes in bounded provider/coordinator telemetry.
- **Telemetry shutdown** — Stop queued slot-posture callbacks after cancellation and wait for the sampler during shutdown, preventing telemetry after teardown returns.
- **Deadline diagnostics** — Report the received prediction policy, reservation ceiling and encoded deadline budget alongside the provider's prediction and decision, distinguishing refusal from acceptance followed by expiry.

#### Companion coordinator and console changes

- **Cache prompt parity** — Match provider JSON response-format instructions and Qwen/Harmony system-turn folding in cache planning so structured-output requests do not generate false prompt-anchor mismatches. Exercise the real service preparation path in shared tokenizer/hash parity tests.
- **Per-model cache reporting** — Add internal breakdowns of provider-reported hits/misses, cached and avoided-prefill tokens, accepted V2 proofs, cache-selected terminals and timing samples. Measure saved-prefill percentages with matched prompt-token denominators for each population; retain invalid/missing usage separately from misses. Add bounded receipt rejection and prompt-length/hash mismatch diagnostics while preserving aggregate public status.
- **Cache evidence continuity** — Preserve unchanged models' holders and receipts when another model loads or changes, retain proof-mismatch fences across unrelated capability updates, and distinguish proof mismatch from ordinary holder changes.
- **APNs reconnect recovery** — Persist verified same-process continuity for bounded coordinator reconnects without refreshing the original Apple proof timestamp. Preserve encrypted resume challenges, token/process/binary binding, new-process freshness checks and Apple push budgets. Stamp final continuity after the socket is offline while keeping periodic updates online-only.
- **Indexed startup recovery** — Recover history through indexed identity lookups instead of scanning every historical session before serving. Select the newest prior session, exclude live/incomplete records and late async writes, preserve live attestation requirements, and publish provider records and reputation atomically. Retry transient store failures within a shared deadline; pending recovery cannot route, and exhausted recovery closes the new registration before evicting an existing session. Preserve legacy missing-reputation behavior while refusing failed reads.
- **Earnings-summary preparation** — Pin missing history before the durable attempt marker and resume per-key additions safely alongside live settlement. Keep base-reward money separate from inference counts/tokens and maintain summaries on record-only inserts as well as account settlement. Add a database-only migration command for approved pre-cutover preparation.
- **Startup measurements** — Add startup phase timings and a read-only post-stop observer that separates candidate health/readiness and per-model routable capacity from optional disposable-test inference. Keep successful inference distinct from answer correctness and omit response text, usage and credentials from reports.
- **Routing deadlines and admission** — Refresh remaining time after registry/provider lock waits before reserving a retained backup, skip expired reservations and shrink an enabled prediction ceiling. Estimate unreflected pending prefill from each request's own prompt size, excluding requests that already produced content, while preserving the proxy for unknown cache work and reflected queues.
- **Incoming request accounting** — Add an unsampled request-outcome ledger and bounded admin inspection with explicit coverage and completion evidence. Record recovered HTTP errors and parsed streaming mode, and distinguish completed, incomplete and error response terminals after successful writes while preserving contradictory evidence and earlier content progress.
- **Partial network geography** — Keep the stats overview available when request-location or route analytics time out. Refresh geography independently, expose unavailable sections, preserve valid empty maps and restore geography after recovery.

## v0.9.0

Published 2026-09-07 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.9.0)).

### Stats request-flow refresh

- Restore Stats refreshes on large usage windows by aggregating request origins before looking up provider locations. Preserve weighted coordinates, request/token counts, and the top-50 flow limit while avoiding large temporary sorts.

### Provider console entry

- Open the provider workspace directly from the console home page, removing the Consumer/Provider selection page. Keep chat and API access in workspace navigation.

### International bank withdrawals

- Add a Stripe Global Payouts route enabled by default in the next production release for additional bank-payout countries, including India, alongside existing Connect withdrawals. Providers review a local-currency estimate before confirming.
- Keep Connect withdrawals independent of browser confirmation storage. Stop automatic retries for ambiguous payouts requiring manual review and show their reserved-funds status in history.
- Show recipient deposit limits and retain quoted Stripe fees for operator review. Continue reconciling existing payouts after funding-account changes and safely release unsubmitted confirmations when payouts are paused.
- Use one earned-balance ledger across both routes, recover confirmations after browser reloads, preserve definitive rejections across refund failures, and reconcile bank returns exactly once. Prune expired unconfirmed quotes. Display sent transfers separately from bank receipt.

### GPT-OSS prefill and decode

- Skip unused GPT-OSS prefill vocabulary projections, fuse compatible 20B expert gate/up weights with bounded load materialization, reuse unchanged quantized constants, and enable the measured width-2880 MXFP4 decode path on M4 Max. Keep rollback controls and unsupported-shape fallbacks.

- Add sequential, provenance-pinned GPT-OSS profiling with full-shape warmups, raw decode token timing, memory measurements, common-window aggregate B=2/B=4 decode rates, and mixed-length arrival workloads. Preserve failed and diagnostic runs separately from valid baseline measurements; raw evidence and paired comparisons distinguish measurement from optimization.

### Hugging Face model downloads

- Add an optional, commit-pinned Hugging Face artifact to each registry version. Foreground model downloads and background prefetch prefer HF, verify the existing per-file SHA-256 and aggregate hashes, and fall back to R2 on download or integrity failure. Existing registry entries keep using R2.

### Qwen non-thinking streaming

- Stream Qwen answers as they are generated when the rendered prompt already closes its thinking block, including image and video requests that default thinking off. Preserve incremental reasoning, explicit parser overrides, and token usage.

### Paged Attention and Qwen Caching (Historical Preparation)

- Preserve provider startup and process diagnostics in the connected cache-routing test, so a two-provider registration failure remains diagnosable before any request runs.

- Prepare automatic paged attention for the three Qwen artifacts, GPT-OSS 20B and Gemma 4 QAT. Scope default SSD caching to Qwen independently of the attention backend; preserve explicit cache opt-in and all backend rollback controls. Model acceptance and operational release validation remain incomplete.

- Verify explicitly enabled Gemma 4 QAT draft tokens with ordinary target-forward shapes to avoid the observed width-dependent token change. Keep assistant drafting and explicit offline rectangular diagnostics; the serialized verification can reduce speculative throughput.

- Retain two-pass attention numerator partials in FP32 through final normalization, avoiding low-precision cancellation and intermediate overflow. Update the shader ABI and generated Swift sources together; model regression validation remains pending.

- Fix recurrent target scoring to use request-owned state and normal peak admission on both KV backends. Preserve ordinary serving dispatch and release state, KV and capacity after failed diagnostics.

- Accumulate affine quantized matrix-vector bias inputs in the wider accumulator type. Regenerate the embedded shader source alongside the Metal library; GPU regressions cover low-precision input cancellation across quantization widths and dispatch shapes.

- Add manual signing/notarization validation without deployment environments or release publication, and exclude the 0.9.0 validation branch from console UI Git deployments. Keep signing/runtime/model approval gates separate.

- Bind GPT-OSS and Gemma optimization settings to SSD checkpoint identities, so changing an optimization or rollback control cannot reuse a checkpoint from the previous numerical configuration.

- Add bounded exact-token ordinary scoring through `darkbloom benchmark --teacher-forced-input`, with explicit model/backend identity, repeated numerical observations and instrumentation controls. These observations do not certify model quality or speculative verification.

- Bound speculative draft depth by useful remaining output slots for every fixed, adaptive and exploration offer. Avoid drafting when only the next target token can be emitted; preserve carry/history and rollback handling.

- Add production-derived single-slot benchmark grants and a cancellation probe that requires a completed donor, actual SSD restoration and exact recovery output. Preserve explicit envelope controls and complete failure evidence.

- Preserve measured SSD restore costs across later Ready estimates for the same checkpoint, without extending measurement freshness or crossing provider/capability changes.

- Add complete native paged checkpoint restore for recurrent Qwen and historical attention windows, with bounded direct export, explicit metadata/auxiliary ownership and cancellation-safe retirement. Real-model release validation remains pending.

- Include excess SSD restore time in coordinator routing costs, so an expensive cache holder can lose to a faster cold peer. Preserve useful-hit discounts, full-request admission and positive-benefit telemetry.

- Expose native allocator padding and released reservation allowance in provider telemetry; avoid scanning unrelated SSD checkpoints on prefix lookup. Verify real allocator ownership and exact capacity refusal.

- Add immutable allocator sizing projections for admission without allocation, locks or error callbacks.

- Reserve native paged allocations using allocator-owned per-buffer bounds, then settle to measured backing bytes. Preserve shared backing ownership, rollback and completion-before-refund checks; provider SSD integration and model performance validation remain pending.

- Add native checkpoint page adoption with typed stage ownership, atomic grant publication and generation-safe retirement. Atomically reserve model loads and bind optional native memory owners to the shared process ledger; production codec and serving-factory integration remain in progress.

- Reject runtime KV dtype mismatches before paged writes and propagate evaluation faults through normal request retirement, preserving native precision and ownership cleanup.

- Report coherent process-memory commitments, materialization, debt and owner counts through optional heartbeat observations. Preserve capture age on replay, validate accounting identities and emit bounded diagnostic metrics without changing routing or capacity authority.

- Capture active, cached and peak MLX memory counters under one allocator lock, so admission can read a coherent accounting snapshot without synchronizing streams.

- Keep live memory reservations charged during prolonged capacity rejection. Remove age-based refunds while preserving bounded diagnostics and background allocator-cache reclamation.

- Report queue-captured paged ownership and allocator refusals through provider heartbeats, coordinator metrics and console types. Preserve capture age, optional instrumentation and reload-safe counter deltas; grant-only updates cannot freshen allocator observations.
- Add private native-page checkpoint filling and bounded byte-preserving export across BF16, FP16 and FP32. Live SSD adoption and the complete paged codec remain under implementation.

- Add runtime B1/B2/B4 benchmark controls with explicit production-bounded KV grants, complete row outcomes, sampled capacity/memory, and strict comparison checks.

- Add an opt-in segmented KV store with native BF16/FP16/FP32 pages, transactional growth, stable buffer identities, and bounded Metal bindings. Verify transfer, allocation rollback, sliding-window and multi-bucket attention mechanics; production backend selection remains unchanged while model and capacity validation continues.
- Account segmented native buffers under each engine's admission budget, including grant shrink, private growth and retirement. Evaluate first-prefill page writes through the normal step roots so native storage is released before its budget is refunded.
- Measure loaded models' native KV types before explicit paged construction and preserve per-layer precision in storage and slot sizing. Enable gated segmented Qwen execution with recurrent/MTP rollback coverage; default selection and complete SSD restore remain contiguous.

### SSD prefix checkpoints

- Preserve native SSD lookup receipts and cache usage when a streamed request is canceled after output; settle only delivered tokens.

- Retain prefix receipts through the provider event pump so successful submission cannot discard routing evidence before durable publication. Preserve terminal and cancellation cleanup.

- Record strict normal-Qwen3.5 paged SSD comparisons at output caps32 and128 after the useful-tail policy. Preserve exact same-budget output identity, natural stopping and the remaining cross-budget numerical difference.

- Record a strict initial Qwen3.6 paged B1 SSD pair with coherent idle observations and normal MTP. Preserve the failed earlier snapshots and distinguish original-native measurements from the later useful-tail policy.

- Reconstruct connected-test reasoning once when SSE includes equivalent compatibility aliases. Reject conflicting values and replay captured streams with different chunk boundaries without weakening output equality.

- Observe published idle snapshots at known benchmark retirement boundaries with a bounded deadline. Preserve timeout/cancellation evidence and keep observation waits outside request latency measurements.

- Record strict initial paged B1 SSD-cache pairs for exact Qwen3.8, GPT-OSS 20B and Gemma 4 26B artifacts. Preserve setup failures, correct the documented local assistant layout, and retain the remaining five-model release gates.

- Require actual off/on cache pairs and retirement evidence in both benchmark arms. Preserve the first Qwen3.6 paged SSD semantic pair and the stricter rejection of stale control snapshots; remaining release gates are pending.

- Bind isolated benchmark cache roots and requested key mode explicitly, reject mismatched actual key mode, and retain cache-construction status on refusal. Preserve production key and native eligibility guards.

- Add an opt-in connected HTTP cache gate using real provider transport and the Rust prompt sidecar. Verify routing, native reuse, tenant isolation, continuation, tools, cold vision, restored cancellation and recovery with exact-artifact paired reports. Helper tests pass; real-model HTTP results remain pending.

- Let production segmented paging use the normal admitted slot KV grant and follow shrink/regrow updates. Delete obsolete eager-pool fractions, caps and minimum checks while preserving native buffer limits, live ownership and shared memory admission.

- Bind complete paged SSD checkpoints to loaded Qwen recurrent and GPT-OSS/Gemma historical-attention capabilities, with exact native storage identity, shared process admission and bounded host I/O ownership. Keep resident payload caching opt-in and paged rollout gated on real-model validation.

- Bind cache plans and prepared receipt owners to one configuration generation. Revoke queued cache scope on reconfiguration or cancellation while preserving ordinary encrypted inference, deadline budgets and authenticated late-receipt cleanup.

- Raise the default shared SSD cache ceiling to 100 GiB, limited to half the volume’s currently available space. Preserve explicit disk-budget overrides and the low-disk write guard.

- Store eligible complete dense Qwen prefix checkpoints on encrypted SSD by default, including supported affine-quantized models, when verified runtime identity and the cache key are available. Preserve attention KV, recurrent state, and normal MTP history. Stream only the matched checkpoint into memory reserved for the active request, with bounded transfer buffers and no retained cache tensors while idle.
- Extend the complete-checkpoint codec to Qwen MoE targets with the same validated attention and recurrent state layout. Add native dtype, fresh-engine restore, branch, isolation and provider wiring tests; full-size model rollout validation remains pending.
- Capture one UTC template date per request across coordinator planning, provider rendering and retries, enabling exact GPT-OSS prompt contracts. Keep unsupported clock formats cold and version the shared normalization and renderer semantics.
- Correct Qwen tool-result grouping and preserve boolean tool arguments. Align coordinator JSON rendering and decimal parsing with the provider, version the renderer contract, and verify exact prompt tokens across all five release models and additional Gemma variants.
- Share immutable parsed tokenizers across verified prompt contracts, while preserving per-contract integrity checks and releasing unused tokenizers. Reduce sidecar memory and construction work without changing prompt tokens or contract identities.
- Bind durable checkpoints to verified weights, prompt contract, runtime, and numerical settings. Validate checkpoint geometry and authenticated segments before adoption; cancelled or incomplete donations cannot publish ready evidence.
- Index verified prefix holders by content across machine epochs, so lookup visits matching holders and enforces the configured per-tier machine limit. Preserve tenant, artifact, expiry, restart and capacity checks.
- Suppress resident cache routing evidence when the provider selects complete SSD checkpoints, including temporary gaps in durable readiness.
- Price verified cache reuse by saved prefill time after staging, capped by the request's prefill work. Preserve load, queue, decode, health and capacity costs; select the cheapest adjusted candidate when cache credit applies. Optional credit caps distinguish absence from explicit zero.
- Route using actual committed checkpoint endpoints, including endpoints below the full prompt boundary. Negotiate the new receipt semantics with the coordinator and preserve compatibility with older peers.
- Allow operators to restrict network prefix caching to exact model, weight, and prompt-contract identities before planning or issuing reusable cache scope. Preserve existing eligibility when the optional list is absent; an explicitly empty list disables participation.
- Report SSD cache use, I/O, donation outcomes and maintenance through typed heartbeat telemetry, with sample age and reload-safe counter deltas. Expose aggregate artifact-list status and keep heartbeat snapshots independent of filesystem sweeps.
- Require `DARKBLOOM_PREFIX_CACHE_MEMORY=1` for resident recurrent checkpoints or paged KV sharing. Retain bounded checkpoint compaction and useful-prefix SSD selection for these explicit memory modes.
- Stream eligible attention-only SSD blocks into evaluated native tensors with bounded decryption buffers and explicit staging reservations.

### Coordinator and provider hot-path cleanup

- Rank routing candidates without temporary lists and assemble streamed tool arguments without repeatedly copying accumulated output. Share SSE sanitization framing and remove unreachable accumulator repair paths.
- Decode provider chat-template controls once, sharing the local request decoder and eliminating batch item reserialization.
- Skip standalone SSD-only weight hashes for known configurations that cannot reuse durable prefixes. Preserve verified pre/post-load hashes for complete Qwen SSD checkpoints, connected attestation, and conservative fallback for unknown configurations.
- Separate inference event handling from token accounting, share terminal cleanup, reuse chosen-token logprob decoding, and remove the unused incremental KV reservation API.

### Stats location refresh

- Restore public stats refreshes on large usage tables by aggregating locations per provider before combining location totals. Preserve distinct-provider and token counts and request-weighted coordinates without sorting every usage row. Keep the selective cutoff's query plan local to the analytics transaction.

### Coordinator performance Tiers 2 and 3

- Cache repeated user and model lookups, batch route telemetry writes, and credit balances in one database statement. Invalidate model caches without allowing older in-flight reads to republish stale entries.
- Coalesce streaming output within a byte cap and parse request bodies once.
- Reduce routing scan work with per-model provider indexes, maintained medians, reusable snapshots, bounded version memoization, and coalesced swap and queue-drain planning.
- Commit reservations under the registry read lock and the selected provider's lock. Keep fault tracking on per-identity gates, with validated rebind and sweep handling; retain `EIGENINFERENCE_RESERVE_COMMIT_MODE=global` as the reservation rollback switch.
- Preserve newer rejection state when capacity-accept bookkeeping arrives late.
- Make scheduler, attestation timestamp, and reputation persistence test fixtures deterministic.

### Provider lifecycle and bounded coordinator work

- Keep genuine provider 502 faults across version changes; only coordinator-marked disconnect flushes are eligible for reset. Count first-scan TTFT rejections in request outcome telemetry.
- Evict capped zombie tracker entries in constant time, preserving recent activity without per-insertion full-map scans.
- Fragment large provider WebSocket messages, bound queue-drain work, and keep control traffic responsive.
- Fence typed draining refusals at ingress before releasing the request slot; preserve newer recovery heartbeats. Graceful restarts remain health-neutral, and late disconnect errors follow identity enrichment without re-quarantining an upgraded provider.
- Correlate cancel sends and terminals atomically, bound version history and telemetry tags, and retain MLX metrics on HTTP-only Datadog deployments.

### 2026-09-04 console redesign

- Provider onboarding specifies macOS 26 or later.
- Added a Consumer/Provider entry page, dedicated `/chat` route, contextual workspace navigation, and public provider onboarding shared with the empty fleet. Linked providers return to their fleet and recorded earnings, including when their Macs are offline; failed discovery never implies an empty account.
- Scoped fleet requests to the current account, cancelling late results on sign-out or account changes.
- Redesigned console navigation, chat composition, searchable model discovery, settings, and API integration examples.
- Redesigned network stats as one continuous overview: an explorable geography
  map, side-by-side request and token charts, graphical model-capacity lanes,
  linked silicon and memory charts, and an expandable provider directory.
- Stats refresh every 30 seconds. Source timestamps survive cache hits; the
  console proxy coalesces requests and bounds fresh caching to 30 seconds. The
  coordinator retains successful snapshots for up to five minutes on refresh
  failures; older source snapshots are marked stale. The page pauses refreshes
  while hidden and distinguishes unknown capacity from zero.

### Coordinator performance Tier 1

- Bound recent in-process usage history with lazy allocation; aggregate dashboard earnings across every row in the rolling windows.
- Refresh public stats and network totals in the background. Preserve unexpired successful data on store failures, return 503 when unavailable, and accept genuinely empty windows.
- Remove capacity-accept bookkeeping from the first-byte path while preserving newer rejection strikes and cooldowns; avoid redundant provider cancels after settled completion.
- Reduce verification polling, coalesce dashboard cache misses, serialize totals queries across windows, batch reputation reads, and throttle successful reputation writes. Add lock-wait/scan instrumentation and preserve unevaluated rejection servability as null.

### 2026-09-03 documentation overhaul

- **Every page under `docs/` rewritten or verified against the code at
  `5d400cf75`** — each page now carries a freshness stamp
  (`> Last updated: <date> · commit <sha>`) naming the code commit its claims
  were checked against; frozen records (`docs/reports/`, `docs/releases/`,
  `docs/legal/`) keep the date and commit of their own last substantive
  change. Claims cite code by path and symbol, not line number. Facts that
  drifted from the code were corrected in place (examples: challenge
  freshness is 16 min not 6; the prefix cache is built only on
  explicitly-paged slots; eviction is two missed 30 s sweeps against a 90 s
  timeout; explicit `max_tokens` is not clamped; the platform fee is stated
  once, in `docs/architecture/billing.md`).
- **Tree reorganised by page type** with `docs/README.md` rewritten as an
  llms.txt-style map (one line per page) and an index per directory.
  `architecture/` holds explanations only — `architecture/operations/*`
  became `architecture/{billing,model-registry,routing,scheduling,telemetry}.md`
  and `architecture/prefix-cache.md`, `architecture/components/admin-ui.md`
  are new; `reference/` gains `configuration.md` (every environment variable
  of the coordinator, provider CLI, console and admin UI, with defaults and
  the symbol that reads it) and `telemetry-inventory.md`; plans and ADRs live
  in `design/` with a status line each (`design/README.md`); dated frozen
  records live in `reports/` (`reports/README.md`; twelve reports that were
  sitting uncommitted are now in the tree); `glossary.md` gives one name per
  concept. Merged as duplicates: `architecture/payments.md` →
  `architecture/billing.md`, `provider/security-model.md` →
  `provider/attestation.md`, `reference/ssd-kv-cache-hybrid-models.md` →
  `reference/ssd-kv-cache.md`; PR screenshot folders removed. Security
  diagrams redrawn from the code (`docs/assets/diagrams/*.mmd` → SVG/PNG).
- **One home per fact** (follow-up to an organisation audit of the new tree)
  — every constant, default, limit and status code is now stated on one owner
  page (`reference/api-contracts.md`, `reference/configuration.md`,
  `reference/pricing-model.md`, the owning `architecture/` page) and linked,
  by identifier, from every other page; operator procedures and SQL recipes
  left the explanation pages for `operations/cache-routing-rollout.md` and
  `operations/profiler-queries.md`; `developer/release.md` became
  `operations/provider-release.md` (it registers releases with production);
  six plan and decision memos moved from `reports/` to `design/` with a
  status line each (`design/README.md` lists all seventeen with status and
  date); `provider/attestation.md` is now the operator how-to for reaching
  and keeping `hardware` trust, and `consumer/privacy-expectations.md` a
  short list that links the encryption page instead of restating it.
- **Docs tooling** — `scripts/docs-stamp.sh` writes or refreshes the stamp
  (`--from-git` for frozen records); `scripts/docs-check.sh` fails on a
  missing or malformed stamp, a relative link that does not resolve, a cited
  code path that does not exist, or a page no index links to. `make
  docs-check` / `make docs-stamp`; `make test` runs the check; CI gains a
  "Docs Lint" job. `docs/AGENTS.md` states the rules for humans and agents:
  one job per page, one canonical home per fact, cite the code, stamp on
  every edit, and the page skeleton for each page type.
- **Root pointers** — `README.md`, `CONTRIBUTING.md`, `AGENTS.md` and
  `CLAUDE.md` point at the new paths, and the "coordinator never sees
  plaintext" claim was replaced by the hop-by-hop encryption model documented
  in `docs/architecture/security/encryption.md`. Code comments that named
  moved docs were updated (comment-only edits in `coordinator/`,
  `console-ui/`, `provider-swift/`).
- **Re-verified against `ac60c5ada` (#816)** — the runtime manifest's
  union-across-active-releases semantics, the `GET /v1/runtime/manifest`
  shape and the `EIGENINFERENCE_KNOWN_TEMPLATE_HASHES` override are stated
  once, in `docs/architecture/security/attestation.md#runtime-manifest`, and
  linked from the provider-release and release-policy runbooks.

### 2026-09-02 system profiler

- **Runtime manifest accepts every active release** — `SyncRuntimeManifest`
  now unions template hashes (including `mlx_metallib`) across ALL active
  release rows instead of keeping one value per template name. Registering
  v0.8.16 on 2026-09-03 replaced the v0.8.15 metallib hash in the manifest, so
  ~1,180 providers still on v0.8.15 failed their next attestation challenge
  (`provider runtime integrity mismatch in challenge response`, 1,184 times)
  and the fleet was unroutable for the ~30–40 minute self-update window.
  Registering a release can no longer deroute the previous release's fleet;
  deactivating a release remains the way to retire its hashes, a hash no
  active release ships still fails closed, and `GET /v1/runtime/manifest`
  lists every accepted hash per template. The post-mutation convergence paths
  and the `EIGENINFERENCE_KNOWN_TEMPLATE_HASHES` override use the same set
  semantics.

## v0.8.16

Published 2026-09-03 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.16)).

### 2026-09-02 system profiler

- **Per-request profiler** — the coordinator records one prompt-free row per
  dispatched attempt in `request_profiles` (joins `inference_routes` on
  `(request_id, attempt)`): microsecond offsets from middleware entry for every
  coordinator stage (auth, parse, reserve, media, preflight, plan, reserve lock
  wait/scan/admit, queue, encrypt, writer submit/dequeue/wire, provider ack,
  chunk ingress, first content, headers, flushes, `[DONE]`, client-gone,
  cancel, completion ingress, settlement), the routing decision context
  (gate rejections by closed reason, top-4 candidates, runner-up, best idle
  alternative, near-tie size, selection path, heartbeat age at decision,
  predicted vs raw TTFT, calibration ratio, queue position/drain trigger), and
  a validated provider profile: the provider now sends an optional `profile`
  object on `inference_complete`/`inference_error` (decrypt/parse/admission/
  model-load wait/prompt prep/engine submit & admitted/first & last delta/
  terminal build & send/cancel stage, plus the engine's own
  `CBv2RequestTiming`: admission, KV allocation, prefill chunks, prompt
  computed, first token, decode steps and batch rows, MTP accept counts,
  pauses, detokenization delay, prefix-cache lookup/adoption). Numbers,
  booleans and closed enums only; validated, folded and stored from a separate
  closed struct; never routing-, billing- or health-affecting.
- **Fleet snapshots** — `fleet_snapshots` samples every provider slot each
  minute (running/waiting, budgets, KV bytes, EWMAs, MTP totals, eligibility
  reason, cooldown/breaker/clamp flags, heartbeat age, cumulative cancel
  counters, low-power/thermal posture) plus a coordinator row (queue depth by
  model, in-flight, sink depth/drops, zombie-frame count). Heartbeats carry new
  optional `telemetry` sub-objects; `eval_in_flight_ms` finally has a producer.
- **Egress and attempt accounting** — non-streaming 200 bodies stamp the same
  first/last flush and bytes-out fields as SSE relays; attempts that never reach
  a provider close only their terminal half at the failure site so the record is
  built after the handler returns; a speculative primary cancelled for the
  first-content timeout keeps its timeout outcome even when the backup wins the
  ingress race.
- **Review hardening** — heartbeat-reported counts are clamped to the snapshot
  column range so one bad heartbeat cannot abort a fleet sample batch; the
  recorded TTFT calibration ratio is the one the candidate was scored with;
  routing replays count `no_provider` / `model_too_large` explicitly; terminal
  usage is recorded at ingress (outside billing) and each provider-profile
  consistency check runs independently; a speculative loser's discarded empty
  completion still closes its attempt row.
- **Operations** — admin browse/NDJSON export for both tables
  (`/v1/admin/profiles`, `/v1/admin/snapshots`), a manual `request_waterfall`
  view, retention sweeps (14 d / 30 d), a dedicated batched profile sink with
  `telemetry.sink_dropped{sink}` / `telemetry.sink_depth{sink}` metrics,
  `inference.unknown_request_frames{kind}`, knobs `EIGENINFERENCE_PROFILER=off`
  and `EIGENINFERENCE_PROFILE_SAMPLE_RATE` (default 0.1; slow, failed, retried,
  backup and client-gone requests are always recorded), routingsim NDJSON
  loaders for profile and fleet exports, `request_rejections.request_id`
  populated with a coordinator-minted id. `X-Timing` keeps its legacy keys
  (clamped, `timing_anomaly` flag) and gains additive `pre_handler_us`,
  `preflight_us`, `route_reserve_us`, `queue_pure_us`, `writer_us`,
  `socket_us`, `provider_ack_us`. Docs: `docs/architecture/system-profiler.md`,
  `docs/reference/telemetry-inventory.md`; threat model T-051.

### Activation Floors and SDK Updates (Historical Preparation)

The final tag pins `mlx-swift-lm` at `c4089870a24b082a9d70f31dc853380e9cff92ca`;
the intermediate pin in the preparation notes below is retained as history.

- **Per-model activation floors + measured resident weights** — the flat
  5.5 GiB activation reserve is now resolved per serving set from measured
  per-model floors (gpt-oss-20b: 3.5 GiB — its load requirement drops from
  20.0 to 18.0 GB, which narrows the 32 GB flap band reported in #653 by ~2 GB; the
  24 GB catalog tier stays borderline until the admit-time weight padding and
  the small-box `memory_reserve_gb` default are revisited, #653/#683), and the coordinator's
  POST-load token-budget estimate uses measured MLX residency for measured
  text-only artifacts (gpt-oss-20b: 11.5 GiB steady vs the 13.5 padded
  estimate) via `servabilityColdWeightsGiB`, version-gated at 0.8.16.
  ADMIT-time gates — provider load gate and the coordinator's cold-load
  admit — deliberately keep the padded disk×1.2 figure: it covers the load
  transient (shard staging), which steady residency does not. Vision-capable models (the qwens, the gemma VLM builds) keep the
  flat floor and padded weights until vision-inclusive measurements exist;
  measured text baselines and the full sweep live in
  `docs/reports/2026-08-30-activation-floor-measurements.md`.
- **Serving-set reserve race hardening** — epoch-stamped reserve pushes
  (cross-actor delivery is not FIFO), in-flight loads join the reserve
  basis, failed-load cleanup holds the load gate through its awaits,
  shrink paths regrow survivor grants, and failed-self-test retirement is
  fail-closed end to end: durable failed-hash record (slot-bound hash or
  refuse-all sentinel) consulted at every prefetch guard, a retirement
  tombstone spanning foreign-owned drains, registration convergence on the
  announce-undo, and new-inference rejection on both resident-slot fast
  paths while a retirement drains.
- **MLX-LM pin advances past the 0.32.2 core bump** — on top of #790's
  `libs/mlx-swift-lm` pin (`81dd564`, which already carried Qwen3-VL CBv2
  DeepStack #125 and the dense Qwen3.8 MTP artifacts #118), this release
  moves to `30da946`: the gather-QMM sorted-hint lane
  ([#126](https://github.com/Layr-Labs/mlx-swift-lm/pull/126)), vision batch
  performance ([#127](https://github.com/Layr-Labs/mlx-swift-lm/pull/127)),
  a serving-correctness batch
  ([#128](https://github.com/Layr-Labs/mlx-swift-lm/pull/128)), and the
  bench-harness hybrid-trunk paged fix
  ([#129](https://github.com/Layr-Labs/mlx-swift-lm/pull/129)).

## v0.8.15

Published 2026-08-29 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.15)).

### Qwen3.8 Dense VLM and MTP (Historical Preparation)

Correction: this release also added `runtime_capabilities` and
`code_attestation_resume_challenge`; the candidate's no-new-fields
statement below was incorrect.

- **Exact Qwen3.8 dense VLM artifact** — Providers serve
  `EigenLabs/Qwen3.8-27B-4bit` at immutable revision
  `301e9e2767fd0efcfab7883004720ba3c9a552a1`. The dense Qwen3.5 text target
  is extracted from the loaded VLM wrapper for ContinuousBatchingV2 while
  retaining shared immutable weights, recurrent/KV sizing, causal visual spans,
  request-owned M-RoPE state, cancellation, deadline, and MLX fault boundaries.
  Image processing remains one tower invocation per image. API video remains
  one full T×H×W tower invocation per video followed by ordered frame-output
  splitting; console/UI video upload is not enabled.
- **Exact separate Qwen3.8 MTP artifact, model-specific default on** —
  `EigenLabs/Qwen3.8-27B-MTP-4bit` at immutable revision
  `329261c5e0b3f9c233485e682cb3b67b88c20a55` is loaded only as a proposal
  assistant; the target remains authoritative for acceptance and output.
  Absent MTP config enables this exact target only. Explicit `mtp_mode = "off"`
  (including `darkbloom beta disable mtp`) and the
  `DARKBLOOM_CBV2_MTP=0` process kill switch independently restore target-only
  decoding. Explicit `on` remains available for other supported targets.
  Missing, malformed, unavailable, incompatible, or memory-inadmissible
  assistant state falls back to target-only decoding with a stable reason.
- **Unified Qwen template and tool controls** — Remote encrypted text/vision,
  local single/batch, and prompt recount paths share one template-control
  value. Nested `reasoning.enabled` wins over top-level or
  `chat_template_kwargs.enable_thinking`; only `none`, `off`, and `0` disable
  through `reasoning_effort`, `minimal` is preserved, media defaults thinking
  off only with no explicit control, and `preserve_thinking` is forwarded.
  Forced Qwen tool calls remain withheld until XML parsing, function selection,
  and schema validation succeed; the exact concrete model advertises the
  capability only for the `qwen3_coder` XML parser contract.
- **Capability-gated rollout and integrity** — The exact concrete model is
  restricted by the shared provider capability evaluator to Apple M5 with the
  approved NAX runtime. `video_preprocessor_config.json` is included in model
  integrity manifests. Provider version advances to `0.8.15`; no protocol
  fields are added.

## v0.8.14

Published 2026-08-27 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.14)).

### Qwen3-VL and Automatic MTP (Historical Preparation)

- **Qwen3-VL 30B-A3B production serving** — The exact
  `qwen3_vl_moe` architecture is admitted through the contiguous
  ContinuousBatchingV2 path. Text decode uses per-row M-RoPE positions; image
  prefill carries causal visual spans, every DeepStack level, and the model's
  embedding activation dtype. Homogeneous routed-expert gate/up projections are
  fused at load time, reducing each MoE layer from three gathered projections
  to two while retaining a strict split fallback for heterogeneous
  quantization. Paged KV, video, packed prefill, prefix reuse, compiled decode,
  and MTP remain fail-closed for this family.
- **Qwen 3.5/3.6 inline MTP defaults to automatic** — New
  `mtp_mode = "auto" | "on" | "off"` keeps Gemma opt-in while valid inline
  `qwen3_5_moe` artifacts activate by default. Explicit `off` and
  `DARKBLOOM_CBV2_MTP=0` remain independent rollback controls. Config schema
  v3 migrates the legacy generated `mtp = false` default to `auto` so upgraded
  providers receive the policy, retains legacy `true` as `on`, and preserves a
  new explicit `mtp_mode = "off"` override.
- Provider and coordinator fallback version authorities move together to
  `0.8.14`; there is no new wire protocol.

## v0.8.13

Published 2026-08-26 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.13)).

### Qwen3.5 Video and Grounded Captions (Historical Preparation)

- **Qwen 3.5 video + grounded image captions** — Qwen vision prefill no
  longer fail-closes video as `invalid media input`. The tower runs one
  video (full T×H×W grid) at a time and carves the contiguous
  `<|video_pad|>` run into per-frame spans. Image decode applies EXIF
  orientation on the full raster (not a JPEG thumbnail). Media requests
  default `enable_thinking=false` unless the client sets
  `reasoning.enabled`. Qwen decodes media once and uniformly samples at most
  8 video frames at no more than 512² pixels each, bounding its unfused
  vision score tensor to 512 MiB. Coordinator remote-media fetch is bounded
  by the leftover first-content clock minus an inference reserve, and media
  bypasses the text-only estimated-TTFT hard gate while retaining the same
  request-absolute deadline. Its incomplete estimates do not train text TTFT
  calibration or emit synthetic warm-pool pressure.
- **Current MLX-LM main pin** — `libs/mlx-swift-lm` advances to `fe01df9`,
  containing the merged Qwen prefill/decode optimization
  ([mlx-swift-lm#120](https://github.com/Layr-Labs/mlx-swift-lm/pull/120))
  and bounded video-tower input fix
  ([mlx-swift-lm#123](https://github.com/Layr-Labs/mlx-swift-lm/pull/123)),
  plus Qwen3-VL 30B-A3B support
  ([mlx-swift-lm#122](https://github.com/Layr-Labs/mlx-swift-lm/pull/122)).
- Provider and coordinator fallback version authorities move together to
  `0.8.13`; there is no new protocol.

## v0.8.12

Published 2026-08-25 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.12)).

### Release Notes

> **Post-publication status:** `v0.8.12` was tagged, published, and registered
> before the Qwen media fixes above. Those fixes therefore ship in v0.8.13.

- **Default atomic first-token deadline admission on** — Explicit typed TOML is
  authoritative: `"off"` disables and `"enforce"` enforces regardless of the
  legacy environment. An absent key inherits that environment, where only exact
  lowercase `off` disables and every other value securely enforces. Optional
  serialization preserves absence. Edit `provider.toml` and use ordinary
  `darkbloom restart` for rollback, restore, or legacy-environment inheritance;
  the linked report gives the exact settings.
- **Keep the safety envelope unchanged** — Forecasting still requires a
  propagated deadline, an initialized isolated cold-prefill EWMA, a text-only
  request, phase-specific rates, and an authoritative capacity-guaranteed
  scheduler projection. Multimodal requests remain outside forecast admission.
- **Keep cap-0 a functional serving rollback** —
  `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0` still restores unlimited partial
  prefill interleave. That posture cannot produce the proven bounded projection,
  so it bypasses forecast admission and uses ordinary submission while hard
  absolute expiry remains active. It does not rewrite the deadline-mode setting.
- Provider and coordinator fallback version authorities move together to
  `0.8.12`; there is no new protocol.

Release rationale, limitations, compatibility, and rollout gates:
[`docs/reports/2026-08-25-v0.8.12-prefill-deadline-admission.md`](docs/reports/2026-08-25-v0.8.12-prefill-deadline-admission.md).

## v0.8.11

Published 2026-08-25 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.11)).

### Release Notes

> **Post-publication status (2026-08-25):** `v0.8.11` was tagged, published, and
> registered as the active provider release. The candidate notes below are
> retained as the pre-publication decision record; their blocker/no-shipment
> language describes the state when they were written. The shipped resolver
> still defaulted atomic deadline admission to `off`; v0.8.12 is the activation
> change.

#### Candidate integration status

- **v0.8.11 enables FCFS partial-prefill scheduling globally** — Production
  resolves `maxConcurrentPartialPrefills` to `1` for every CBv2 model. Operators
  can immediately restore the historical unlimited interleave with
  `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0`; other explicit non-positive or
  malformed values also fail open to unlimited behavior.
- **Deadline conservation and atomic admission plumbing ships
  provider-default-off** — Remaining first-content budget propagation is
  additive and fail-open for older peers. The queue-excluded prefill EWMA,
  engine atomic forecast API, and provider wiring are integrated, but forecast
  enforcement remains disabled unless exact mode `enforce` is selected.
  Default-on FCFS is the separate global scheduling policy above.
- **FCFS evidence remains a release blocker** — Cap 1 can improve mean burst
  TTFT, but it can also remove Qwen packed-prefill cohorts and head-of-line-block
  short prompts. The only real-model attempt was aborted after approximately
  27 minutes at 13% battery and produced no artifact. No signed-candidate
  cap-0/cap-1 report or representative non-Qwen evidence exists yet.

#### Coordinator candidate fixes

- **Enforce one request-absolute first-content deadline** —
  Queueing, provider acceptance, boilerplate/preamble frames, speculative
  dispatch, and blocked provider writes must not reset the clock. Expiry must
  cancel in-flight work and return the existing retryable `429` contract
  without feeding provider-fault breakers unless the provider received a full
  attributable wait window.
- **Price routing from live prefill behavior** — The base request-cost
  term now uses the same measured-preferred prefill resolver as TTFT estimation,
  falling back to the static registration rate when no observation exists.

#### Provider candidate fixes

- **Default partial-prefill concurrency to one with an immediate rollback** —
  The production factory applies cap 1 globally. Exact environment override
  `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=0` restores unlimited interleave without
  a code change.
- **Honor the coordinator's remaining first-content clock** —
  A positive wire budget becomes one provider-local monotonic deadline. The
  provider refuses expired pre-submit work and releases any partial
  admission/cache resources instead of restarting the budget at model load or
  engine submission when enforcement is enabled. Default-off and absent
  metadata paths remain fail-open; coordinator cancellation remains the
  authority after submission.
- **Add an honest FCFS evaluation harness** — The opt-in five-workload matrix
  compares caps 0 and 1, cryptographically records the selected checkpoint,
  omits local model paths, records source/binary/build/hardware/OS/power/thermal
  posture, and evaluates the documented 5% throughput and TTFT thresholds. Its
  schema distinguishes simulation, unsigned local evidence, and evidence
  captured by the signed packaged main executable. Signed Qwen evidence remains
  model-family evidence only and never sets global release certification.
- **Add a fail-closed signed-artifact FCFS command** — Run the exact packaged
  candidate with:

  ```bash
  "$SIGNED_APP/Contents/MacOS/darkbloom" benchmark \
    --scheduler-prefill-decision \
    --model "$QWEN_MODEL_ID" \
    --expected-model-aggregate-sha256 "$QWEN_MODEL_AGGREGATE_SHA256" \
    --expected-registered-binary-sha256 "$REGISTERED_DARKBLOOM_SHA256" \
    --expected-version 0.8.11 \
    --source-sha "$SOURCE_SHA" \
    --decision-iterations 10 \
    --kv-backend auto \
    --output "$QWEN_SIGNED_REPORT"
  ```

  It accepts no weights path and resolves the canonical registry ID internally.
  It exits successfully only after packaged signature, identifier/team,
  registered binary hash, version, model hash, posture, and policy checks pass.

#### Release requirements

- Pass coordinator/provider focused tests, protocol symmetry, mixed-version
  behavior, full builds, system E2E, signed artifact checks, and rollback gates
  recorded in
  `docs/reports/2026-08-24-qwen-openrouter-timeout-fix-and-release.md`.
- Do not ship the default-on FCFS policy until an externally captured
  signed-candidate artifact passes the cap-0/cap-1 criteria on representative
  Qwen hardware, plus equivalent latency/throughput/head-of-line evidence for
  every affected non-Qwen CBv2 family or a separately reviewed model-scoped
  policy. The unsigned local harness cannot satisfy this requirement.

---

The entries below are earlier shipped releases. At the time the v0.8.11
candidate notes above were recorded, the latest shipped provider was `v0.8.10`.

## v0.8.10

Published 2026-08-22 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.10)).

### Release Notes

#### Provider (Swift)

##### Fixes

- **Seed retained optimization latches before packaged-child exec** — The v0.8.9 curl installer could download and verify the signed bundle but reject it with `safe R1 was not latched as requested` on hosts where MLX initialized Metal before `runtime-smoke.run()`. Installer, self-updater, and paged preflight children now receive the exact retained three-key environment (`DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=18`, `MLX_GEMMA4_FUSED_WEIGHTED_UNSORT=1`, `MLX_GATHER_QMM_EXPERT_SLICES=1`) at process launch, while the child still poisons/reapplies/verifies the values and AOT kernels. Existing installations remain untouched on any failed verification.

## v0.8.9

Published 2026-08-21 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.9)).

### Release Notes

#### Provider (Swift)

##### Fixes

- **Emergency Qwen3.6 runtime rollback** — Restores the v0.8.7 `mlx-swift-lm` pin (`ab73a827`) and removes v0.8.8's default-on GDN four-input projection fusion and direct weighted-expert reduction. In the fixed one-hour production comparison, Qwen success fell 85.52%→65.79%, p50 decode fell 38→26 tok/s, client timeouts approximately doubled, and the hard TTFT gate emitted 612 429s (602 marked counterfactually serveable). M1/M2 providers regressed even though they cannot use affine `qmv_wide`, isolating the Qwen runtime changes as the first rollback target. Gemma's merged `qmv_wide` MLX/MLX-Swift pins remain enabled for continued benefit and separate attribution.
- **Restore the retained runtime-smoke contract** — Removes the retired Qwen process-global reduction key from serving projection, launchd passthrough, signed-child validation, and benchmark-report expectations. Provider artifact verification returns to the three retained Gemma controls.

## v0.8.8

Published 2026-08-21 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.8)).

### Release Notes

#### Provider (Swift)

##### Performance

- **Default-on small-batch quantized matvec (`qmv_wide`)** — Ports upstream MLX #3764 (`548dd80e`) into the Darkbloom MLX fork and regenerates MLX-Swift's embedded JIT Metal sources. On generation-15+ Apple GPUs, affine BF16 W4/W8 dense projections with `2 <= M < vector_limit` reuse each decoded weight group across the small activation-row tile; M=1 remains on QMV, matrix-sized inputs remain on QMM, and gathered expert projections are unchanged. Source-built metallib and release-artifact checks require representative W4/W8 ordinary and batched symbols. Local M4 Max directional medians preserved B=1 and improved Gemma B=4 aggregate decode 195.93→216.94 tok/s at 512 context (+10.72%) and 143.18→155.72 tok/s at 8K (+8.76%); B=2 was +4.49%/−1.00%. The attempted 32K comparison is intentionally unclaimed because both benchmark arms entered a persistent degraded host/device state.

##### Default posture

- `qmv_wide` is an automatic Metal dispatcher route, not a beta flag: eligible generation-15+ affine `2 <= M < vector_limit` projections take it by default. Gemma layer-18 submission, coupled weighted-unsort/safe-R1, expert-tile trust, solo-prefill stripe, prompt narrowing, and packed-prefill defaults remain enabled for existing and new provider configurations.

## v0.8.7

Published 2026-08-20 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.7)).

### Release Notes

#### Provider (Swift)

##### Fixes

- **Restore Qwen3.5/3.6 system-history normalization** — The compatibility fix released on the `v0.8.5` branch was absent from master and therefore from `v0.8.6`, causing Qwen's published template to reject OpenAI-compatible histories with a late system turn (`System message must be at the beginning`). Production Qwen 422s rose from 3.46–4.95% on `v0.8.5` to 27.73–33.95% on `v0.8.6`. Text-only system turns are again folded into one leading system message before generic tool-history validation; structured/media system content remains fail-closed.

## v0.8.6

Published 2026-08-20 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.6)).

### Release Notes

#### Provider (Swift)

##### Performance

- **CBv2 prefill stack, default-on** — Cold prefill 6,406.8 → 4,636.9 ms at 8K on the M4 Max prod artifact (**~1,766 tok/s, +38% vs v0.8.5 defaults**); 4×8K burst aggregate 1,312 → ~1,500 tok/s (+13–17%) with token-checksum parity across every arrival pattern. Four independently escapable levers (#646, mlx-swift-lm#111):
  - *Expert-tile `trust` serving default* — skips the per-chunk descriptor retract drain (80 stream drains/chunk); exact `MLX_GATHER_QMM_EXPERT_SLICES=1` restores the drain posture. (#638)
  - *Solo-prefill stripe (2048)* — when exactly one live text request holds the scheduler, its chunk widens 512→2048 (weights streamed 4× less often, full 32-row expert tiles). Armed per-plan; any company disarms to plain 512s; KV-capacity failure shrinks once, never preempts; the stripe budget belongs exclusively to the armed row. `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE=0` disarms. **Known trade: ~12% TTFT regression under Low Power Mode — throttled/battery providers should export the escape.**
  - *Recurrent prompt narrowing (Qwen LM head)* — intermediate chunks return a one-element handle instead of the `[1,512,248320]` logits tensor (242.5 MiB/chunk); the frontier chunk norms + projects exactly one row. `DARKBLOOM_CBV2_PREFILL_NARROWING=0` restores byte-old behavior.
  - *Packed prefill (Qwen3.6)* — equal-length prompt chunks from concurrent requests run as one `[B,L]` forward with per-row recurrent state (one weight stream per cohort; text-only v1).
- **Mean-TTFT prefill serialization** *(opt-in)* — `DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=1` caps rows receiving prompt work per step (FCFS): burst TTFTs become a staircase instead of everyone waiting for the makespan. Paused rows hold no slot (a stalled consumer cannot head-of-line block admission). (#646)
- **Adaptive persistent-history MTP promoted onto master** *(still behind the `mtp` beta flag)* — the v0.8.5-described capture-verify stack's adaptive width selection and persistent head KV now ship in the release pin. (#641, mlx-swift-lm#110)

##### Benchmarks / Tooling

- Scheduler-prefill report schema 3 (records the effective stripe posture); Gemma contbatch wrapper schema 6 — baseline pins refuse pre-default-flip reports so the posture change can never masquerade as a code delta. 14 review-hardening scheduler fixes with regression tests; measurement methodology + posture discipline in `docs/reports/2026-08-19-solo-prefill-stripe-experiment.md`. (#646)

### Adaptive Persistent-History MTP

- **Qwen3.6 MTP: adaptive persistent-history capture-verify stack** *(behind the `mtp` beta flag, default off)* - Selects one rectangular k=0...4 per scheduler plan/decode-row bucket from request-local acceptance probabilities and shared marginal-cost evidence, obtains policy confidence with a lazy hierarchical Metal top-2 reduction, and keeps complete committed context in request-owned MTP-head KV; leading trusted history now appends K/V only, so each round computes full head output only for its final row. Target verification remains one `[B,1+k]` forward with target-prefix-authoritative acceptance at any temperature. Widths 1/2 use captured recurrent state; S>=3 runs one full-window recurrence, commits the final state directly on full acceptance, and retains compact transformed inputs for lazy strict-prefix replay instead of full per-position recurrent stacks. Request-owned head/history and recurrent replay residency are charged exactly by admission. A combined production-bundle **DEBUG canary validation** on this M4 Max measured median target 7.657386s vs MTP 3.813989s (**2.0077x**); this is validation evidence, not release throughput. (#616, mlx-swift-lm#106/#108/#110)

## v0.8.5

Published 2026-08-15 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.5)).

### Release Notes

#### Provider (Swift)

##### Performance

- **Qwen3.6 E=256 expert-tile prefill route + fused gate_up** - Instantiates the Gemma4 descriptor/tile kernel family for Qwen's 256-expert shapes (mlx `d3c82db`), fuses the routed gate/up projection into one gather (`SwitchGLU(fuseGateUp: true)`, per-layer and per-load with heterogeneous-quantization split fallback across every checkpoint key space), and adds the opt-in `trust` refinement that skips the per-chunk retract drain. Measured on M4 Max, prod artifact: routed MoE block -26.3% at T=512; end-to-end prefill 1243→1364 tok/s default, 1433 with `trust` (+15.2%) at 8k; 2k +7.4%, 32k +6.6%. (#617, mlx-swift-lm#107)
- **mlx gpu::eval use-after-free fix** - A stale `MTL::CommandBuffer` captured across `eval_gpu` could crash any primitive that syncs mid-eval (deterministic SIGSEGV on the E=256 route; previously survived on allocator luck). (mlx#5/#7)

##### Fixes

- **Inline-MTP inspection resolves HF-cache symlinks and rejects loudly** - Symlinked snapshots (the standard HF `blobs/` layout) silently disabled inline MTP: `inspectInlineArtifact` required regular files and reported nothing. Inspection now resolves links and validates targets; every genuine rejection logs a concrete reason and path. Untrusted operator-path inspection stays symlink-rejecting. (#618)

##### Observability

- **MTP posture and acceptance on the local `/metrics` endpoint** - `mtp_enabled`, `mtp_active`, `mtp_rounds_total`, `mtp_tokens_proposed_total`, `mtp_tokens_accepted_total`, and `mtp_inactive_reason{model,reason}` (including `inline_artifact_invalid`) in both `--local` and unified serving modes - acceptance was previously observable only in Datadog Logs. (#619)

#### Coordinator

##### Fixes

- **Expose exact Hugging Face repositories in model feeds** - Registry metadata can now override `hugging_face_id` independently of the internal routing ID. Both `/v1/models` and `/v1/models/openrouter` honor the override for concrete and aliased models, with an authenticated `hugging-face-id` admin action for existing registry rows. (#620)

---

### Provider Privacy Fixes

- **Keep inline video plaintext off disk** — The provider decodes coordinator-inlined MP4/QuickTime bytes through a bounded, memory-backed AVFoundation asset, retains the byte owner through metadata probing and frame sampling, and rejects external asset references. Exact-name legacy `vlm-<UUID>.mp4` files are purged once after single-instance lock acquisition on both coordinator-connected and standalone launch paths.

- **Close unintended provider-derived plaintext egress paths** — Provider inference failures cross the WebSocket and client boundary only as closed-vocabulary codes/reasons, while browser/provider free-form telemetry and automatic provider log reporting are retired. The explicit `darkbloom report` support command remains operator-initiated, preserves macOS unified-log privacy redaction, supports local `--dry-run` review, and uses authenticated upload plus admin-only retrieval.

## v0.8.4

Published 2026-08-13 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.4)).

### Release Notes

#### Provider (Swift)

##### Fixes

- **Stream Qwen3.6 reasoning deltas immediately (TTFT fix)** - Qwen3.6-style chat templates pre-open the `<think>` block at the prompt tail, so model output carries only the closing tag and the streaming think parser buffered the entire block before emitting anything: measured prod TTFT was `755ms + 12.51ms x reasoning_tokens` (r = 0.9878) while the first byte arrived in ~76ms. The engine now probes the rendered prompt tail (`ReasoningPromptProbe`) and injects one synthetic `<think>` open ahead of model output — gated on an active think-format parser and streaming — so `reasoning_content` streams per chunk and TTFT reflects real first-token latency. Text and VLM paths; the marker never reaches the prompt, the consumer, or the TB-007 hash domain. (#614)

---

## v0.8.3

Published 2026-08-13 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.3)).

### Release Notes

#### Provider (Swift)

##### Features

- **Qwen3.6-35B-A3B VLM with inline MTP** - Adds production-path text, image, and tool inference for the combined Qwen artifact. The runtime preserves request-owned recurrent and three-axis mRoPE state, causal vision attention, exact rollback, and source-matched target/assistant memory accounting. MTP remains depth-one, serial, and exact-target-verified; video, prefix reuse, paged KV, compiled decode, packed prefill, and rectangular MTP remain fail-closed.

##### Release Safety

- The model is registered as beta/ready without an alias or active-version promotion. Provider rollout and model promotion remain separate reviewed operations after the signed `v0.8.3` bundle passes a controlled fleet canary.

---

## v0.8.2

Published 2026-08-12 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.8.2)).

### Release Notes

#### Provider (Swift)

##### Performance

- **Gemma 4 26B-A4B v0.8.2 optimization stack** — Layer-18 lazy prefill submission; coupled weighted-expert-unsort + safe-R1 expert-QMM gate (both default-on via `[gemma_optimizations]`); the VLM wrapper's directly shared text tower; packed multimodal prefill inside q=128 query blocks; source-matched metallib enforced across CI/release/packaged smoke. Final performance and retention deltas are pending a same-tree A/B measurement on the reviewed release tree. Earlier gitignored measurements predated the final kernel edits and are not release evidence. Dropped before the final cut: expert gate/up packing, dense gate/up packing, standalone weighted-unsort, standalone R1. `0cc5fc9c9`


---

## v0.5.0

Published 2026-05-25 ([release](https://github.com/Layr-Labs/d-inference/releases/tag/v0.5.0)).

### Apr 26 - May 25, 2026 development snapshot

The cited development commits first enter the stable `v0.5.0` tag. This
snapshot is not a final-artifact specification: `serve` was not a shipped
Swift subcommand, `BatchedEngine` superseded `BatchGenerator`, and the
production hard-fail-on-Swift-tests setting was removed before this tag.

26 commits since `aa74499`.

#### Coordinator

##### Features

- **DB-backed model registry** (#203) -- Model catalog is now stored in Postgres with R2-hosted manifests. Includes readable prefixes, runtime limits, runtime parameters, hardened validation, and provider inventory preservation across catalog updates. `50e8887b`
- **Token-budget routing with engine-level admission** (#171) -- Replaces heuristic-based routing with engine-reported capacity signals. Providers report real `activeTokens`, `maxTokensPotential`, and token budget usage. Coordinator uses EWMA observed TPS, fleet median fallback, and token-budget admission. 5 new fields on `BackendSlotCapacity` (backward-compatible). 25+ new tests. `78314b4e`
- **Speculative TTFT dispatch** (#171) -- Parallel dispatch to a backup provider at 50% of the TTFT deadline. First provider to deliver a token wins; loser is cancelled. No double-billing. OpenRouter TTFT SLA enforcement (5s base + 1ms/input token). `78314b4e`
- **Early 429 with Retry-After for capacity signaling** (#171) -- Returns 429 instead of 503 when fleet is at capacity (no uptime penalty on OpenRouter). `GET /v1/models/capacity` endpoint for observability. `ModelCapacitySnapshot` with per-model routable/warm/cold providers, aggregate TPS, estimated TTFT, and token budget headroom. `78314b4e`
- **Coordinator-driven model preload protocol** (#110) -- New `load_model` / `load_model_status` WebSocket messages allow the coordinator to push model warm-up requests to providers ahead of demand. `56b050b4`
- **Datadog observability stack** (#143) -- DogStatsD, APM, journald log collection on dev GCE VM. Structured metrics: attestation counters, model_type tags, provider-count gauges, completion-tokens counter, fleet version/binary hash observability, billing histograms (reservation, settlement, provider credits, platform fees), store latency, input token metrics. `56b050b4`
- **X-Timing latency decomposition header** (#136) -- Single JSON header with per-phase microsecond breakdown: `parse_us`, `reserve_us`, `route_us`, `queue_us`, `encrypt_us`, `dispatch_us`, `provider_us`. `56b050b4`

##### Bug Fixes

- **Structured JSON 404 for unimplemented /v1/* endpoints** (#168) -- Catch-all handler returns `application/json` errors instead of Go's default `text/plain` 404. Prevents OpenAI SDK parse failures on `/v1/embeddings`, `/v1/moderations`, etc. Added openai-go SDK compatibility tests. `e108da5f`
- **OpenAI error response `code` and `param` fields** (#144) -- `errorResponse` now populates `code` and `param` per the OpenAI API spec. `insufficient_quota` canonical code, `param="model"` on model errors. All 202 existing call sites backward-compatible. `e108da5f`
- **Require country for Stripe payout onboarding** (#179) -- `2e262b73`
- **Stripe dashboard metadata** -- `35582c82`
- **Prevent double-decrement on untrusted provider disconnect** (#143) -- `MarkUntrusted` race fix: hold write lock through counter decrement. Heartbeat no longer revives untrusted providers. `56b050b4`
- **Skip Python/dangerous-modules check for Swift runtime** (#143) -- Private text routing gate correctly bypasses Python-specific checks for Swift providers. `56b050b4`
- **Fix planner pending leak** (#171) -- Changed `planner.complete()` to `planner.cancel()` in request completion path. Without this, pending entries accumulated until `maxQueuedRequests` (128), permanently bricking the provider. `78314b4e`
- **Refund provider-specific extra on generic dispatch** (#171) -- All 14 failure paths after `reserveAdditionalForProvider` now refund the delta in `handleGenericInference`. `78314b4e`
- **activeRequests counted per-model, not per-provider** (#171) -- `ModelCapacitySnapshot` now counts only pending requests matching the specific model. `78314b4e`
- **Link test providers to user account** (#174) -- Ensures payout destination check passes for test providers. `f4219c4f`

##### Breaking / Protocol Changes

- **Go module path changed** -- `github.com/eigeninference/coordinator/internal/X` -> `github.com/eigeninference/d-inference/coordinator/X`. Module path is now `github.com/eigeninference/d-inference`. `coordinator/internal/` flattened to `coordinator/`. `56b050b4`
- **Bundle filename changed** -- Coordinator now accepts `darkbloom-bundle-<platform>.tar.gz` (was `eigeninference-bundle-`). `56b050b4`

---

#### Provider (Swift)

##### Features

- **Swift provider runtime shipped** (#110) -- Full `darkbloom` CLI with `serve`, `start`, `stop`, `status`, `doctor`, `models`, `benchmark`, `login`, `logout`, `enroll`, `update`, `verify` subcommands. Production inference via MLX-Swift on Apple Silicon. GPU-only enforcement. Rename from `eigeninference` to `darkbloom` with backward compatibility. `56b050b4`
- **Continuous batching** (#110) -- All concurrent requests merged into one batched forward pass per step via `BatchGenerator`. Bit-identical against single-stream greedy. Near-linear throughput scaling (B=4/B=1 = 3.8x on Qwen, 2.9x on Gemma MoE). `56b050b4`
- **Multi-model concurrent serving** (#167) -- `953b8f02`
- **MLXLMServer adoption for OpenAI protocol** (#208) -- `ca8983c4`
- **BatchedEngine migration** (#207) -- `BatchScheduler` migrated from `BatchGenerator` to `BatchedEngine`. `80fc0ee7`
- **Idle-timeout model unload** (#110) -- Provider unloads model after 60 minutes idle (configurable). Next request lazy-reloads. `56b050b4`
- **Persistent Secure Enclave key** (#146) -- Replaces ephemeral CryptoKit SE keys with persistent Security framework keys in the macOS data protection keychain. Bound to signing team's keychain access group. .app bundle with embedded provisioning profile. `56b050b4`
- **Token budget engine-level admission** (#171) -- `BatchScheduler` reports real token budget usage. EWMA decode TPS tracker. Engine-level admission gate rejects with `token_budget_exhausted`. Dynamic token budget sized from model weight bytes and available memory. `78314b4e`
- **Architecture-aware kvBytesPerToken** (#171) -- Computed from config.json metadata (layer count, KV heads, head dim) instead of weight-bytes heuristic. Handles hybrid attention (Gemma 4), GQA/MQA, recurrent layers (Qwen3.5), and VLM wrappers. 4x reduction on Qwen3.5 models. `78314b4e`
- **Rust-to-Swift bridge auto-update** (#110) -- Rust provider auto-updates to Swift bundles, rewrites launchd plist, handles .app bundle layout. `56b050b4`

##### Performance

- Greedy fast-path optimization: `nil` sampler for temperature=0 uses vectorized fallback (+6-13% decode TPS). `56b050b4`
- mlx-swift-lm double buffering, UInt32 token tensors. `56b050b4`
- Release-mode BatchGenerator B=4 matches mlx_lm Python reference (Qwen: ~1130 vs 1119 tok/s; Gemma: ~186 vs 181 tok/s). `56b050b4`

---

#### Console UI

- **Refresh earn calculator and landing page** (#185) -- `ed6d655e`
- **Fix Next.js version vulnerability** (#172) -- `2f65bb41`
- **Analytics tracking fix** -- `f7dab6fa`

---

#### Testbed / E2E

- **Integration test suite** (#136) -- 12 E2E tests with real Swift provider (Postgres + coordinator + provider per test). Tests: NonStreaming, Streaming, Concurrent, Encryption, Billing, Payout, Referral, InsufficientBalance, InvalidModel, AttestationHeaders. `56b050b4`
- **Load generator and profiling** (#136) -- Configurable concurrency, streaming, benchmark CI with PR comment posting. Heavy-load 100-concurrent 10KB benchmark. Latency regression assertions. `56b050b4`
- **Performance test suite** (#110) -- Warm/cold TTFT, encrypted E2E, batched throughput, decode-TPS bracket tests for Qwen 0.6B and Gemma 26B MoE. `56b050b4`

---

#### Security

- **Harden release registration and binary hash policy** (#99) -- Release download URL derived from allowlist. `b5dd0488`
- **Harden release workflow protections** (#103) -- `e515244f`
- **Rust-to-Swift cutover hardening** (#110) -- Post-codesign verification of entitlements, provisioning profile validation (team ID, access group, expiration), MLX wheel pinning, prod hard-fail on Swift tests. `56b050b4`
- **STRIDE threat model** (#110) -- 40 threats across 9 trust boundaries. Automated PR review workflow via Claude API. `56b050b4`
- **Typed response structs for OpenAI endpoints** (#166) -- `7fbfa9fc`

---

#### Billing

- **Remove deprecated Solana/wallet-based provider payouts** (#178) -- `fe994fc9`

---

#### CI / Infrastructure

- **Migrate CI workflows to Blacksmith** (#182) -- `ff8527a4`
- **CI runs on any PR** (#119) -- Not just master/main. `98a3a024`
- **Remove racing deploy-dev-coordinator workflow** (#137) -- Eliminates race condition with Cloud Build. `cf4c0efa`
- **DEV_/PROD_ prefixed repo secrets** -- Environment-scoped R2 + coordinator secrets for release isolation. `56b050b4`
- **Native Postgres fallback for CI** -- Docker/colima replaced with `initdb + postgres` on macOS runners. `56b050b4`
- **Correct version comments for SHA-pinned actions** (#160) -- `85cedc7e`

---

#### Housekeeping

- **Remove unused dependencies** (#112) -- `7ccc592f`
- **Remove stale Python integration test** (#109) -- `e6d63a86`
- **Bump mlx-swift and mlx-swift-lm submodules** (#206) -- Re-homed to Layr-Labs forks. `5919dac1`
- **Darkbloom license agreement** (#173) -- `dde67b28`
- **Update README** (#176) -- `7451a473`
