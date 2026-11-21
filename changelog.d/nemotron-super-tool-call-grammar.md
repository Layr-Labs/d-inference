### Nemotron 3.5 Super: tool-call arguments follow the declared tools, with or without images

- Super's `auto` tool calls are now sampled under the call grammar Lightning uses, for every declared tool, on text,
  image and video requests. A call can only name a declared function and its declared parameters, includes every
  required parameter, and writes enum values and the JSON types the schema allows. Reasoning and text stay free, and
  the model still decides whether to call.
- A parameter with an assertion the grammar cannot hold (for example a numeric bound or a string format) keeps its type,
  structure and enum values; only that assertion is left to the model.
- Requests with a reasoning budget (`reasoning.max_tokens`), requests whose unfinished reasoning becomes the answer
  (`force_nonempty_content` with thinking on), forced tool choices and requests the grammar cannot hold are served as
  before.
- On a Mac where Super drafts with its MTP head, a text request held by the grammar keeps drafting: through its free
  reasoning and text, and inside a call with drafts verified under the grammar (`DARKBLOOM_CONSTRAINT_SPANS` and
  `DARKBLOOM_CBV2_MTP_GRAMMAR` now default on for Super). `DARKBLOOM_CONSTRAINT_SPANS=0` keeps such a request
  target-only; `DARKBLOOM_CBV2_MTP_GRAMMAR=0` keeps it target-only inside a call. Image requests decode target-only, as
  before.
- `DARKBLOOM_NEMOTRON_SUPER_TOOL_GRAMMAR=off` restores unconstrained calls for Super. It is separate from
  `DARKBLOOM_NEMOTRON_TOOL_GRAMMAR`, which governs Lightning.
