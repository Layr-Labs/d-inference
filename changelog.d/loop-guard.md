### Answers that repeat themselves verbatim stop early, as `length`

- An answer that starts repeating one block of text word for word now stops after about 2,000 repeated tokens instead of running to its output limit (up to 131,072 tokens, 25–40 minutes on one Mac). It ends like an answer cut at `max_tokens`: `finish_reason` is `length`, the usage counts the tokens produced, and the request is paid as usual. The Mac is free for the next request sooner.
- Only exact repetition counts: the last 2,048 tokens or more must repeat one block of 8–512 tokens at least 8 times in a row, and never within an answer's first 4,096 tokens. A tool call, a JSON answer and a forced tool call are never cut.
- On by default for Gemma 4, Qwen 3.5/3.6/3.8, GPT-OSS, Nemotron 3.5 Lightning, GLM-5.3 and MiMo. Nemotron 3.5 Super is not covered yet: its requests take Super's own route. `DARKBLOOM_LOOP_GUARD=0` turns it off.
