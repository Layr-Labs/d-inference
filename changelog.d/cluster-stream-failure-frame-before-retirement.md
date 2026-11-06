### A two-Mac pair's local API no longer cuts a failed stream short

- When the provider rejects a streamed chat completion's output mid-generation on a pair (for example a named or required `tool_choice` the model answers with text, or a streamed tool call that fails validation), the leader's local API now ends the stream with the same error chunk (`finish_reason: "error"`) as one Mac. Before, if the pair had not yet retired the cancelled request, the stream stopped after the chunks already sent, without the error chunk, and the connection closed in the middle of the HTTP transfer.
