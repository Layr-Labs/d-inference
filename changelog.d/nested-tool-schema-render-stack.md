### A deeply nested tool schema no longer ends the provider

- A request whose tool schema nested about 30 levels deep (for example an array of arrays, 30 times) ended a provider serving Gemma 4 26B with a bus error: the chat template formats a schema with a recursive macro, and the render ran on the request's 512 KiB stack. A 620-byte request was enough. The template now renders on a thread of its own with a 16 MiB stack, which holds the 64 levels a request may nest. Rendered prompts and their tokens are unchanged.
