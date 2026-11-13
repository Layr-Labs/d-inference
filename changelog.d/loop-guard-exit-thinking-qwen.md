### A Qwen 3.5 or 3.6 35B thought that repeats itself verbatim now ends in an answer

- As for Gemma 4 in 0.10.13: when the loop guard stops a verbatim loop inside a Qwen 3.5 or 3.6 35B thought, the request no longer ends as `length` with no answer. The provider ends the thought as Qwen's template does (`\n</think>\n\n`), and the model writes its answer in the same response. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`.
- Since 0.10.12, 1.6–2.6 % of GPQA-shaped requests to these two models ended that way with no answer.
- On by default for `qwen3_5_moe` (Qwen 3.5 35B, Qwen 3.6 35B). Not by default for `qwen3_5` (Qwen 3.5 9B, Qwen 3.8 27B). Never with logprobs or on a cluster pair. `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text` keeps Gemma's alone; `gemma4,gemma4_text,qwen3_5_moe,qwen3_5` adds the 9B and Qwen 3.8 27B; `0` turns it off.
- Client stop strings apply to the answer from its first token, and a stop string that ends the answer is reported as the matched stop sequence (Gemma 4's too).
