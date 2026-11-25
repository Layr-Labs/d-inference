### Inkling 2 Mini logprobs cover only the answer

With `logprobs` on, Inkling 2 Mini returned entries for its thought and its message markers whenever its reasoning was returned (thinking on, or no reasoning setting), so `logprobs.content` did not join to `content`. In every reasoning mode, streamed or not, it now returns entries only for the answer's tokens, each with its `top_logprobs`. Requests with thinking off already worked this way and are unchanged.
