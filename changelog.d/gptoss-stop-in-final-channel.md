### GPT-OSS stop sequences apply to the answer only

- A client `stop` sequence on GPT-OSS models such as `gpt-oss-20b` now
  matches only the Harmony `final` message, the text returned as `content`.
  It used to match the private analysis too, so a sequence that appeared
  while the model reasoned (for example `"\n\n"` or `"."`) ended the request
  before any answer: `finish_reason` `stop`, reasoning only, empty content.
  Tool-call arguments are never cut either. Other models keep whole-output
  matching.
