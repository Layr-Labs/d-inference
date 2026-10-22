### Faster prompt preparation and admission

- Prompt preparation reuses the token IDs of chat-template pieces (the text
  between special tokens) already seen in the same prefix-cache scope, so a
  follow-up turn of a long conversation no longer re-tokenizes its history.
  Token IDs equal the previous path's; a load-time self-check and sampled
  background comparisons disable reuse on any mismatch, including a prompt
  the previous path would have rejected. On an M3 Ultra a
  27–38K-token follow-up turn now prepares in 5–8 ms instead of 102–264 ms,
  and new long prompts prepare 2.3–3.4× faster, encoded on several cores.
  `DARKBLOOM_TTFT_PROMPT_CACHE=0` restores the previous path.
- Gemma 4 and GPT-OSS chat templates rescanned the whole history for every
  message, so render time grew with the square of the history length: 0.72 s
  for 1,603 Gemma messages on an M3 Ultra, on every request. Cached
  prompts now render through equivalent linear-time forms of those loops
  (26 ms for the same history), checked against the served template at load
  and in the background comparisons. A 610-message, 44–46K-token agent loop
  now prepares a follow-up turn in 15–21 ms instead of 213–346 ms. In an
  end-to-end tool loop of about 400 messages and 18–22K tokens, every request
  reached its first token 45–152 ms sooner on Gemma 4 and GPT-OSS.
  `DARKBLOOM_TTFT_TEMPLATE_LOOPS=0` keeps the served template.
- The Jinja null sanitizer returns plain string, number and Boolean leaves
  without reflection: 5.4 ms instead of 12.5 ms for a 603-message history.
- For requests without tools or legacy function calls, the decrypted request
  body is parsed once for the chat request and its extension fields instead
  of five times.
- A request waiting for a cold model load (other than native MiMo) no longer
  holds the coordinator work queue: resident models' requests, cancels and
  attestation challenges proceed while it loads, and a cancel for it still
  applies when its admission returns. A request for another model that is not
  resident still waits for that load, so its capacity check sees the memory
  the load takes. A request for the model being loaded that fails that check
  while the load runs is checked again once the load returns, as before.
  `DARKBLOOM_TTFT_COLD_LOAD_RELEASE=0` restores the serial queue.
