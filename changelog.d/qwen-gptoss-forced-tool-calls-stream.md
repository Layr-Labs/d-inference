### Qwen 3.5–3.8 and GPT-OSS forced tool calls stream to clients that stream

- A tool call forced by `tool_choice` `required` or a named function on Qwen
  3.5 9B and 35B, Qwen 3.6, Qwen 3.8 or GPT-OSS 20B was held back until
  generation ended, so a long tool answer had no first content before then
  (GPT-OSS's analysis aside) and could miss the coordinator's first-content
  deadline. It now streams to a client that streams, as Gemma 4's forced
  calls and every family's `auto` calls do: the name first, then the argument
  fragments as they are generated.
- Each call is still checked in full when its frame closes; one that fails
  after it started is refused with its check, never finished. Qwen's forced
  calls have no sampler grammar, so such a refusal now comes after the name
  left instead of before any content. Text outside the call is still refused,
  GPT-OSS's analysis is still shown as reasoning, and a cut at the token limit
  still ends `length`.
- Clients that do not stream get the same complete-call output as before.
  `DARKBLOOM_TTFT_STREAM_FORCED_QWEN_TOOL_CALLS=0` and
  `DARKBLOOM_TTFT_STREAM_FORCED_GPTOSS_TOOL_CALLS=0` (or `off`, `false`, `no`)
  withhold one family's forced calls again;
  `DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS=0` withholds every family's.
