### Qwen 3.5, 3.6 and 3.8 parse tool calls after the thinking

- On Qwen 3.8, Qwen 3.6, Qwen 3.5 35B and Qwen 3.5 9B, tool calls were parsed before the thinking was split off. A
  thought that mentioned `<tool_call>` once (for example "I'll wrap it in `<tool_call>` tags") made the response's real
  call come back as text, with no call; a call the model wrote out inside its thinking was executed. The thinking is
  now split off first, as on Bonsai 2, Nemotron 3.5 Lightning and MiMo: tool syntax in the thinking stays in
  `reasoning_content`, and the calls after it arrive as `tool_calls`.
- `auto` calls still stream while they are generated, forced calls (`required` or a named function) keep their
  behavior, and requests without tools are unchanged.
