### Stop sequences no longer match Gemma 4 or `<think>` reasoning

- A client `stop` sequence on Gemma 4 models such as `gemma-4-26b-qat-4bit`,
  and on models that reason in `<think>` blocks (Qwen 3.5, 3.6 and 3.8,
  among others), now matches only the text returned as `content`. With
  reasoning on, it used to match the reasoning too, so a sequence that
  appeared while the model reasoned (for example `"."` or `"\n\n"`) ended the
  request before any answer: `finish_reason` `stop`, reasoning only, empty
  content.
- With tools declared, tool-call frames are not cut either, except a frame
  whose arguments quote its own closing tag, or a bare `<function=…>` frame
  written without its wrapper. When a request has no tool handler (no declared
  tools, or a media request on a family without native media tools), a literal
  tool tag in an answer is text the client receives, and stops still apply to it.
  Whitespace before the answer's first character (the blank line after
  `</think>`) cannot complete a stop sequence on its own.
- A stop sequence that names a marker no longer fires on it: `</think>`, or
  `<tool_call>` with tools declared.
