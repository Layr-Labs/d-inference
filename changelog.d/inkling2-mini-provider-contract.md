### Inkling 2 Mini: provider prompt and output contract

- The provider reads Thinking Machines' Inkling 2 Mini (`inkling2_loop`) from its own configuration: its looped
  cache layout (48 cache slots per sequence, 8 full-attention and 40 sliding-window), still-image input without
  video, and its separate DSpark drafter file (`mtp.safetensors`) as the checkpoint's inline assistant. The native
  text model and its vision wrapper serve on paged KV only; images enter as causal tokens, video is refused.
- Its template renders with the Transformers-compatible `tojson` filter, which its tool declarations and tool-call
  history require. Tool declarations and earlier tool calls' arguments render as the client sent them (`null`s
  kept, no inferred schema types, argument member order kept), and a message's list of text parts renders part by
  part, as the model's reference renders them, on every request. An image in a tool result is read in its place,
  as the reference reads it. An image in an assistant or system message is refused before decode with HTTP 400
  `invalid_request` and refusal `media_role_not_rendered` by default, or `invalid_media` with
  `DARKBLOOM_MEDIA_ON_EVERY_ROLE=0`. A `developer` message is still read as `system`.
  The template self-check no longer renders a video part for a model that takes no video.
- Reasoning effort: each of the seven names reaches the template as its own level (`none` 0 through `xhigh` and
  `max` 0.99). Turning thinking off renders effort 0, and whatever the model still thinks is counted but not
  returned. The shared `reasoning_effort_vectors.json` gains the family's cases.
- Its output is read by its own message tokens: reasoning, answer text and one JSON call per call message. A call
  drafted inside a thought stays reasoning, markers inside argument strings are data, nesting and sizes are bounded,
  and a malformed call is refused. Required and named tool choices are prompt-forced and each call is checked before
  it leaves; to a client that streams, each call leaves when its message closes.
- The reasoning-loop guard covers Inkling 2 as it does the other served families: a reply repeating verbatim ends
  as `length`, and a call message turns the guard off. Its exit from a repeating thought is in place but stays off
  until measured (`DARKBLOOM_LOOP_EXIT_THINKING=inkling2_loop` turns it on).
- The DSpark drafter serves by default (up to 7 drafts and 8 speculating rows, adaptive depth); image rows run without
  it. Before serving, every draft depth also runs once on a private engine with its own scratch memory, so a first
  request no longer compiles verify widths mid-stream.
- Loading Inkling 2 warms its first full prefill chunk and its decode and drafter shapes before it serves, so the
  first request no longer pays the first-chunk cost (`DARKBLOOM_TTFT_SHAPE_WARMUP=0` turns it off).
- Another role's turn marker stops generation. The upstream model id serves on paged KV with the prefix cache on
  by default.
- Follow-up turns reuse their prefix: complete checkpoints of Inkling 2 carry every cache slot (full-attention
  history, sliding windows, convolution and recurrent state, and the drafter's history when it drafts), on whole
  2,048-token prefill chunks, in the same encrypted store with the same cache identity and tenant scoping as every
  other model. Before, its loads reported the prefix cache disabled (`unsupported_layout`).
- Inkling 2 prefills in 2,048-token chunks with no solo stripe. Under the generic 512-token chunk and 2,048-token
  solo stripe, the engine's fixed prefill grid refused every prefix checkpoint, so follow-up turns reused nothing.
- After its load warm-up, Inkling 2 resets the MTP depth policy's measured step costs (`EngineV2.resetMTPCostLearning`),
  so the first served request measures them. The warm-up's cold first steps had recorded a plain decode step at 96-99 ms
  (it normally takes 15 ms), every draft round then looked free, and the policy drafted at its maximum depth: one served
  stream of code on an M5 Ultra ran at 107 tok/s, and runs at 121-123 with the reset. Tokens are unchanged.
- Inkling 2's MTP picks each row's draft depth from the measured cost of each window depth (mlx-swift-lm snapshot 2.13). On
  an M5 Ultra four served streams run at 63 tok/s each on code (was 50) and 86-88 on prose (was 70-73); six streams at 50 on
  code (was 44-45) and 62-63 on prose (was 59). Tokens are unchanged.
