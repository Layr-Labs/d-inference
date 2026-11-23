### Gemma 4: an optional guard against a tool-call close with no call open

- Gemma 4 sometimes ends a tool-calling answer after a few tokens: it writes the call close `<tool_call|>` with no
  call opened, then `<|tool_response>`, which ends generation. The client gets no call and no text.
- `DARKBLOOM_GEMMA_ORPHAN_CALL_GUARD=on` samples Gemma 4 text requests that declare tools with `tool_choice` `auto`
  under a token constraint that refuses `<tool_call|>` while no call is open (and a second one right after a close);
  `strict` also refuses `<|tool_response>` except right after a call closes. Every other token stays allowed, so an
  answer that never draws those tokens is unchanged.
- Off by default. It applies on one Mac that runs token constraints, to requests without media or a presence or
  frequency penalty; forced tool choices keep their grammar, which already admits a close only after a call. The
  LaunchAgent forwards the variable.
