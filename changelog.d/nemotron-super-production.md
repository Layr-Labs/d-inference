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
  vs 2.7294).
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
  Coordinator-side registration remains a separate step.
