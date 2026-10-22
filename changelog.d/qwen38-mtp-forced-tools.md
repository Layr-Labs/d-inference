### Qwen3.8 forced tool calls

- The embedded-MTP Qwen3.8-27B build now advertises `tool_choice` `required`
  and named-function support, like the original build it replaced, and forced
  calls accept the catalog's default `qwen3_5` parser instead of failing with
  an invalid request.
