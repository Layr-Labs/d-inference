### `darkbloom logs` names why a request was refused while its prompt was prepared

Requests refused as client errors while the provider prepared the prompt, such
as GLM-5.3-Flash tool histories with an unanswered call or an unmatched result,
history arguments it cannot represent, tool names it refuses, or a prompt plus
`max_tokens` beyond the context window, logged only the bare
`Inference failure: invalid request`. They are most of the HTTP 400s a GLM
provider returns. Each now names a fixed reason, for example
`Inference failure: invalid request (unanswered tool call)`, so the 400s can be
attributed from `darkbloom logs`. The line never contains request text, and the
refusal itself is unchanged.
