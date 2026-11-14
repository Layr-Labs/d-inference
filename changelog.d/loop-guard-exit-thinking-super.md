### A Nemotron 3.5 Super thought that repeats itself verbatim can end in an answer (off by default)

- Once turned on, as for Gemma 4 in 0.10.13 (and the Qwen 3.5/3.6 35B models, when listed): when the loop guard stops a verbatim loop inside Super's thought, the request no longer ends as `length` with no answer. The provider ends the thought (`</think>`, as Super's template does), and the model writes its answer in the same response. The usage counts every token produced, as one completion. A loop in the answer still ends as `length`.
- Since 0.10.12, 3.0 % of GPQA-shaped Super requests ended that way with no answer.
- Off by default until its A/B: `DARKBLOOM_LOOP_EXIT_THINKING=gemma4,gemma4_text,nemotron_h_omni` turns it on beside Gemma 4's (the default); adding `qwen3_5_moe` turns on the Qwen 3.5/3.6 35B models' too; `0` turns all of them off. Never with logprobs, media or on a cluster pair.
