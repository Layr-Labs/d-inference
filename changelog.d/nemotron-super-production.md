### Nemotron 3.5 Super served natively

- Discovers and advertises exactly `nvidia-nemotron-3.5-super`: the complete
  pinned NVIDIA NVFP4 checkpoint with its embedded MTP head. The registry id
  with an unpinned `config.json` or index is withheld; every other
  `nemotron_h_omni` id stays unsupported, as before. Its advertised memory is
  the managed LOAD footprint plus one image request's media charge (122.3 GiB
  for the default configuration), and it advertises image input; capacity
  quotes for image probes charge their images.
- Loads into a shared slot through a managed owner: the ordinary eviction and
  re-slice, one LOAD claim covering the installation, the head and the
  configured requests' KV headroom, every shard verified against its pin, an
  owner-wide prefill lane, and a refusal naming the minimum when the grant
  cannot serve every request. Defaults: exact rectangular speculation for up
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
  `logprobs` are refused with 400.
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
- Opt-in paged attention KV (`DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND=paged`): the
  segmented native paged backend, charged by the engine's process-memory owner,
  with the decode rows reserved for the owner's lifetime; it never falls back to
  contiguous storage and keeps the text prefix bank off.
- Serves 65,536 tokens of context, prompt plus output (was 16,384); the runner
  can select up to 262,144 tokens. The speculating owner charges each request
  its draft history per token of its own prompt and output instead of for the
  whole window, so eight requests claim 22 GiB of KV headroom beside any
  prefix bank (was 26 GiB).
- Needs at least 192 GB of unified memory; only 256 GB is measured.
  Coordinator-side registration remains a separate step.
