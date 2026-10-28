### Qwen 3.5/3.6 stop looping to max_tokens

- Requests that omit sampling fields now use the model cards' thinking-mode values (temperature 1.0, top_p 0.95, top_k 20, presence_penalty 1.5) on the catalog Qwen3.5-9B, Qwen3.5-35B-A3B and Qwen3.6-35B-A3B builds instead of greedy decoding. On 20 prompts, runaway repetition fell from 7 to 0 (9B), 8 to 0 (3.5 35B) and 3 to 0 (3.6 35B). Explicit request values still win.
