### A Qwen 3.5 or 3.6 thought that repeats itself verbatim now ends in an answer

- As for Gemma 4 in 0.10.13: when the loop guard stops a verbatim loop inside a Qwen 3.5 or 3.6 thought, the request no longer ends as `length` with no answer. The provider ends the thought as Qwen's template does (`\n</think>\n\n`), and the model writes its answer in the same response. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`.
- Since 0.10.12, 1.6–3.0 % of GPQA-shaped Qwen 3.5/3.6 requests ended that way with no answer.
- Qwen 3.5 and 3.6 (`qwen3_5`, `qwen3_5_moe`). Not Qwen 3.8, whose thought loops are rare. Never with logprobs or on a cluster pair. `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text` keeps Gemma's alone; `0` turns both off.
- Stop strings apply to the answer from its first token.
