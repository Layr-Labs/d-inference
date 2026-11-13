### A Nemotron 3.5 Super thought that repeats itself verbatim now ends in an answer

- As for Gemma 4 and the Qwen 3.5/3.6 35B models: when the loop guard stops a verbatim loop inside Super's thought, the request no longer ends as `length` with no answer. The provider ends the thought (`</think>`, as Super's template does), and the model writes its answer in the same response. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`.
- Since 0.10.12, 3.0 % of GPQA-shaped Super requests ended that way with no answer.
- On by default for `nemotron_h_omni`. Never with logprobs, media or on a cluster pair. `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text,qwen3_5_moe` leaves Super's off; `0` turns all of them off.
