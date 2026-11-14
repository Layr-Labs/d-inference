### A Qwen 3.5 thought that repeats itself now ends in an answer

- When the loop guard stops a verbatim loop inside a Qwen 3.5 9B or Qwen 3.5 35B thought, the provider now closes the thought as the model's template does (`\n</think>\n\n`), and the model writes its answer in the same response, instead of ending as `length` with no answer. Gemma 4 and GPT-OSS already did this.
- TODO(A/B): on GPQA Diamond at OpenRouter's settings (temperature 0.5), N of M looping answers were rescued, X % of them right. Requests where the guard does not fire are unchanged (token-identical when sent one at a time).
- The request's stop strings apply to the answer from its first token. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`.
- On by default for these two builds only. Qwen 3.6 and Qwen 3.8 27B, which share their model families, keep `length` until their own A/B. `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text,gpt_oss` turns Qwen's exit off; a list with `qwen3_5_moe` or `qwen3_5` turns it on for every build of that family.
