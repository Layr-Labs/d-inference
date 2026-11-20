### Chat templates render on a thread with a larger stack

- The provider renders chat templates on a thread of its own with a 16 MiB stack instead of the request's 512 KiB one. Templates that format a tool schema with a recursive macro, such as Gemma 4's and GPT-OSS's, now render schemas nested up to the 64 levels a request may carry. Rendered prompts and their tokens are unchanged.
