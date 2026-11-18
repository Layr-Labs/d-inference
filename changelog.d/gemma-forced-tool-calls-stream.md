### Gemma 4 forced tool calls stream to clients that stream

- A Gemma 4 26B tool call forced by `tool_choice` `required` or a named
  function was held back until generation ended, so a long tool answer had no
  first content before then and the coordinator's first-content deadline cut
  it off (GEMMA-504: 93 % of Gemma's 504s). It now streams to a client that
  streams, as `auto` calls do: the name first, then the argument fragments as
  they are generated.
- Each call is still checked in full when its frame closes; one that fails
  after it started is refused with its check, never finished. Text outside the
  call is still refused, and a cut at the token limit still ends `length`.
- Clients that do not stream get the same complete-call output as before.
  `DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS=0` (or `off`, `false`, `no`)
  withholds forced Gemma calls again.
