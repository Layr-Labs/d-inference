### A two-Mac pair's local API no longer cuts a failed stream short

- When the provider rejects a streamed chat completion's output mid-generation on a pair (for example a named or required `tool_choice` the model answers with text, or a streamed tool call that fails validation), the leader's local API now ends the stream with the same error chunk (`finish_reason: "error"`) as one Mac. Before, the client could get HTTP 200 and the chunks already sent, then the connection closed with no error chunk. Some clients took that cut-short stream for a complete answer.
