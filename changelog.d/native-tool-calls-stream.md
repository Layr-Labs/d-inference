### MiMo V2.6, Nemotron 3.5 and Bonsai 2 tool calls stream to clients that stream

- MiMo V2.6, Nemotron 3.5 Lightning, Nemotron 3.5 Super and Bonsai 2 (9B,
  27B) held every tool
  call (`auto`, `required` or named) back until generation ended, so a long
  tool answer had no first content before then and the coordinator's
  first-content deadline cut it off. To a client that streams, these calls
  now leave as they are generated: the name first, then the argument
  fragments.
- Each call is still checked in full when its frame closes; one that fails
  after it started is refused with its check, never finished. A forced
  answer is still calls only, reasoning still leaves first, and a cut at the
  token limit still ends `length`. A Super frame that does not parse is
  still refused, as for clients that do not stream.
- Clients that do not stream get the same complete-call output as before.
  `DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS=0` (or `off`, `false`, `no`)
  withholds these families' calls again; `DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS`
  off withholds their forced calls, as every other family's.
