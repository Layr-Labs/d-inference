### `parallel_tool_calls: false` returns the first tool call instead of failing the response

- With `parallel_tool_calls: false`, a model that made a second call failed the whole response: a streamed answer ended in an error after its first call had already been sent, and a complete answer was a 422. Nothing in the prompt asks the model for a single call, so this was the provider failing a valid request.
- The response now carries the first call, as OpenAI and vLLM return it, and the calls the model makes after it are dropped. This holds for every model and path, Nemotron Super's included, streamed or not.
