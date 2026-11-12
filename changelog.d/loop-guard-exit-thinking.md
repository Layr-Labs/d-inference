### A Gemma 4 thought that repeats itself verbatim now ends in an answer

- When the loop guard stops a verbatim loop inside Gemma 4's thought, the request no longer ends as `length` with no answer. The provider ends the thought (`<channel|>`), and the model writes its answer in the same response. The client sees the thought close and the answer start. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`, as in 0.10.12.
- The answer gets what is left of the request's output budget, at most 8,192 tokens. If it cannot start (no budget left, a full Mac, a cancel), the request ends as `length`, as before.
- Gemma 4 only (`gemma4`, `gemma4_text`). Never with logprobs or on a cluster pair. `DARKBLOOM_LOOP_EXIT_THINKING=0` turns it off.
