### Nemotron 3.5 Super served natively

- Discovers and advertises exactly `nvidia-nemotron-3.5-super`: the complete
  pinned NVIDIA NVFP4 checkpoint with its embedded MTP head. The registry id
  with an unpinned `config.json` or index is withheld; every other
  `nemotron_h_omni` id stays unsupported, as before. Its advertised memory is
  the resident checkpoint plus the larger of its load transient and the
  serving room (prefill lane, requests' KV headroom and one image request's
  media charge; 97.6 GiB for the default configuration), and it advertises image input; capacity
  quotes for image probes charge their images.
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
- Serves inline JPEG and PNG images (`data:` URIs) on the same slot. On the
  default speculating owner each image request runs target-only, with no
  draft state, while text keeps speculating; its media reservation, including
  the largest image's tower and projector bound, is taken before decoding and
  a reservation that does not fit is refused with 503. A second concurrent
  image request gets 429. Activation overflow on the Super model saturates as
  on deployment engines instead of becoming NaN, so images whose embeddings
  exceed the text-calibrated scales are answered instead of decoding as
  `<unk>`; non-finite image features fail the request.
- A load right after a Super unload re-samples free memory for up to two
  seconds while macOS returns the unloaded pages, instead of refusing.
- Plain decode steps of the Super owner commit larger Metal command buffers
  (thread-scoped limits in the pinned MLX), and full SSD prefill windows run
  batched, with tokens unchanged: one plain request decodes at 42.9 tok/s
  instead of 34.6 on the full checkpoint. Speculative rounds are unchanged.
- Paged attention KV by default (`DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND`, `paged`
  unless set to `contiguous`): the segmented native paged backend, charged by
  the engine's process-memory owner, with the decode rows reserved for the
  owner's lifetime; it never falls back to contiguous storage. Exact prefix
  reuse works on it: the bank keeps its own copy of a donor's prompt KV and a
  restore writes it into fresh pages.
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
