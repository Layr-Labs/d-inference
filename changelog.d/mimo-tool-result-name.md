### MiMo-V2.6-Flash serves tool results whose `name` differs from the call

A tool result whose optional `name` was empty or differed from its call's
function, such as the unprefixed tool name some MCP clients send, was refused
with HTTP 400. Results pair with calls by `tool_call_id`, and MiMo's chat
template never renders a result's `name`, so these histories are now served.
