### GLM-5.3-Flash tool calls stream to clients that stream

- GLM-5.3-Flash held every tool answer back until generation ended, so a long
  tool call had no first content before then and could miss the coordinator's
  first-content deadline. Its calls, `auto` and forced, now stream to a client
  that streams: the name once the frame is unambiguous, then string arguments
  as they are generated.
- Each call is still checked in full when its frame closes; one that fails
  after it started is refused with its check, never finished. Forced answers
  stay calls-only, a cut at the token limit still ends `length`, and reasoning
  is split off first, so a call drafted in a thought is never a call.
- Clients that do not stream, JSON `response_format` answers and media get the
  same output as before. `DARKBLOOM_TTFT_STREAM_GLM_TOOL_CALLS=0` (or `off`,
  `false`, `no`) withholds GLM calls again.
