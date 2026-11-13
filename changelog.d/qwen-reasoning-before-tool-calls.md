### Qwen 3.5, 3.6 and 3.8 parse tool calls after the thinking

- On Qwen 3.8, Qwen 3.6, Qwen 3.5 35B and Qwen 3.5 9B, tool calls were parsed before the thinking was split off. A
  thought that mentioned `<tool_call>` once (for example "I'll wrap it in `<tool_call>` tags") made the response's real
  call come back as text, with no call; a call the model wrote out inside its thinking was executed. The thinking is
  now split off first, as on Bonsai 2, Nemotron 3.5 Lightning and MiMo: tool syntax in the thinking stays in
  `reasoning_content`, and the calls after it arrive as `tool_calls`.
- A call the model writes at the very end of a thought it never closes (a known Qwen 3.5 habit) still arrives as a
  call; a call followed by more thinking, or by the end of the thinking, does not.
- `auto` calls still stream while they are generated, and requests without tools are unchanged. Forced calls
  (`required` or a named function) still run with thinking off; a stray thought the model writes before one is now
  returned as `reasoning_content` instead of failing the request.
- A local `stream: false` response for these requests keeps the whitespace around its content and reasoning, as the
  streamed response does.
