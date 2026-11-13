### A GPT-OSS analysis that repeats itself now ends in an answer on requests without tools too

- When the loop guard stops a verbatim loop inside GPT-OSS's analysis on a request without tools (or with `tool_choice: "none"`), the provider ends the analysis and opens the final channel (`<|end|><|start|>assistant<|channel|>final<|message|>`), and the model writes its answer in the same response, instead of ending as `length` with an empty answer. In 0.10.13 the exit applied to requests with tools only: given the choice, the model reopened its analysis and looped again on every GPQA question that looped.
- The request's stop strings apply to the answer from its first token. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`.
- On by default. `DARKBLOOM_GPTOSS_FINAL_EXIT=0` restores 0.10.13's behaviour (the exit for requests with tools only); `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text` turns GPT-OSS's exit off altogether.
