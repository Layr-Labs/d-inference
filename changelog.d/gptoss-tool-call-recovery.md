### GPT-OSS tool calls written as the answer or inside the analysis are returned as calls

- For an `auto` request that declares tools, GPT-OSS sometimes answers after
  the loop guard ended its analysis with the call's JSON arguments and no
  recipient, or writes a complete call frame at the end of an analysis it
  never closes. The provider now returns such an answer as the call when it
  is a single JSON object that exactly one declared tool admits (every key a
  declared property, the schema holding), and such a frame when it is
  complete, names a declared function and its arguments hold. Anything else
  is returned as before. No rendered prompt changes.
- `DARKBLOOM_GPTOSS_TOOL_CALL_RECOVERY`: `0`, `off`, `false` or `no` turns it
  off.
