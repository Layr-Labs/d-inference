### A stray `<tool_call>` no longer fails a GLM-5.3-Flash response

- GLM's tool parser reads a response from its first `<tool_call>` to the end as one batch of calls, and on `auto` tool requests that includes the model's reasoning. A tag the model only mentioned or a call it drafted in its thought, or a text answer that mentions the tag, failed the whole response with a 500 (`native GLM tool output is invalid`).
- Such output is now returned the way vLLM's and SGLang's GLM parsers return unmatched markers: as text. The calls are the frames that parse to the end of the response; everything before them is text, so the reasoning still splits at `</think>`. Output with no such calls (a malformed or cut-off final call, text after the calls, an output cut at `max_tokens`) is all text. No call is completed or salvaged.
- Required and named `tool_choice` still fail closed (422). `DARKBLOOM_GLM_TOOL_TEXT_FALLBACK=0` restores the 500; `darkbloom start` passes it to the launchd provider.
