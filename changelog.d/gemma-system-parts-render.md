### Gemma 4 system messages render as text parts, as vLLM renders them

- A Gemma 4 26B request with a system (or developer) message now renders it as the chat template's text parts, which end in a space before the system turn closes, as vLLM-served endpoints render every such request. `usage.prompt_tokens` and the prompt the model reads match theirs: OpenRouter's GPQA prompt is 88 tokens, not 87. List-shaped system and user content keeps its parts instead of being joined first, as Transformers renders it.
- Requests the coordinator planned for its prompt cache keep the prompt of their plan, so their cache receipts still match; media requests and other models are unchanged. `DARKBLOOM_GEMMA_SYSTEM_PARTS_RENDER=off` restores the previous render on a Mac.
