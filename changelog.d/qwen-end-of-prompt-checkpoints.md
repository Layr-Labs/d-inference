### Dense Qwen conversations restore almost all of the previous turn

- A dense Qwen 3.5/3.8 request served alone prefills in 4,096-token stripes,
  so its deepest SSD checkpoint was the last full stripe end, up to 4,095
  tokens before the prompt end. The next turn of the conversation
  re-prefilled that gap. Such a request now also ends a prefill range just
  below its prompt end (at least 64 tokens before it, on the 256-token grid)
  when that saves at least 1,024 tokens, and the next turn restores from
  there. In a six-turn conversation from 30K to 55K tokens on Qwen3.5-9B (M3
  Ultra), the summed time to first token of the five follow-up turns fell
  from 57.4 s to 47.9 s, with identical outputs. Busy providers, which
  prefill in 512-token chunks beside decoding requests, and the short-prompt
  fork checkpoint are unchanged.
