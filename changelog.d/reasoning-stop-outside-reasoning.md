### Stop sequences no longer match Gemma 4 or `<think>` reasoning

- A client `stop` sequence on Gemma 4 models such as `gemma-4-26b-qat-4bit`,
  and on models that reason in `<think>` blocks (Qwen 3.5, 3.6 and 3.8,
  among others), now matches only the text returned as `content`. With
  reasoning on, it used to match the reasoning too, so a sequence that
  appeared while the model reasoned (for example `"."` or `"\n\n"`) ended the
  request before any answer: `finish_reason` `stop`, reasoning only, empty
  content.
- Tool-call frames are never cut either, and whitespace before the answer's
  first character (the blank line after `</think>`) cannot complete a stop
  sequence on its own.
