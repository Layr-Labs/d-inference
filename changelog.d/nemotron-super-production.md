### Nemotron 3.5 Super served natively

- Discovers and advertises exactly `nvidia-nemotron-3.5-super`: the complete
  pinned NVIDIA NVFP4 checkpoint with its embedded MTP head. The registry id
  with an unpinned `config.json` or index is withheld; every other
  `nemotron_h_omni` id stays unsupported, as before. Its advertised memory is
  the managed LOAD footprint plus one image request's media charge (126.3 GiB
  for the default configuration), and it advertises image input; capacity
  quotes for image probes charge their images.
- Loads into a shared slot through a managed owner: the ordinary eviction and
  re-slice, one LOAD claim covering the installation, the head and the
  configured requests' KV headroom, every shard verified against its pin, an
  owner-wide prefill lane, and a refusal naming the minimum when the grant
  cannot serve every request. Defaults: depth-3 exact rectangular speculation
  for up to eight requests; `mtp_mode = "off"` or `DARKBLOOM_CBV2_MTP=0` serves
  the plain owner, which also reuses exact text prefixes when the grant holds
  its bank, and an explicit `engine_v2_max_concurrent` bounds the width.
- Coordinator and local-endpoint chat completions use the reference prompt
  template, reasoning channel, tool and structured-output validation,
  cancellation and usage of the owner. Prefix reuse is partitioned by the
  authenticated cache scope and reports no cache use. `logit_bias` and
  `logprobs` are refused with 400.
- Serves inline JPEG and PNG images (`data:` URIs) on the same slot. On the
  default speculating owner each image request runs target-only, with no
  draft state, while text keeps speculating; its media reservation, including
  the largest image's tower and projector bound, is taken before decoding and
  a reservation that does not fit is refused with 503.
- Needs at least 192 GB of unified memory; only 256 GB is measured.
  Coordinator-side registration remains a separate step.
