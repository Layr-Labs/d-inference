### Qwen tensor-parallel prompt wavefront

- A Qwen tensor-parallel pair now prefills a text prompt in steps of up to
  eight consecutive 512-token frames built as one graph, layer by layer: while
  one frame's sealed sum crosses the link, the next frame computes. Every frame
  keeps its own shapes and kernels, so logits, KV, recurrent state, prefix
  captures and tokens are unchanged. Steps run two frames while another lane
  decodes and end at the prompt-cache capture point. Media prompts, assisted
  (MTP) prompts, packed KV and routed-expert models keep one frame a step.
- The merged step's frames in flight are charged in LOAD, the placement quote
  and each request's charge (about 367 MB a Qwen3.8-27B rank at one lane).
- `darkbloom-cluster-tp-check qwen-prefill --wavefronts 1,8` and
  `darkbloom-cluster-tp-check qwen-wavefront` measure the merged steps on one
  rank and on two ranks over the loopback ring.
  `DARKBLOOM_QWEN_TP_PROMPT_WAVEFRONT=0` restores one frame a step for
  diagnosis; both ranks must agree.
