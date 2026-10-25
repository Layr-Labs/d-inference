### Legacy `function_call` histories keep their result paired with the call

A conversation in OpenAI's legacy function-calling format, an assistant
`function_call` followed by a `role: function` result, was converted to
`tool_calls` but left the result without a call ID, so GLM-5.3-Flash refused it
with HTTP 400 as an unmatched tool result. The result now takes the converted
call's ID, and GLM-5.3-Flash serves the history like its `tool_calls` spelling.
