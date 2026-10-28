### Qwen3.5-9B stops looping to max_tokens

- Requests that omit sampling fields now use the model card's thinking-mode values (temperature 1.0, top_p 0.95, top_k 20, presence_penalty 1.5) on the catalog Qwen3.5-9B build instead of greedy decoding. On 20 prompts, runaway repetition fell from 7 to 0. Explicit request values still win.
