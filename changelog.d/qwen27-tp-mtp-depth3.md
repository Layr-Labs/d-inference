### Qwen27 tensor-parallel speculative depth 3

Automatic Qwen27 tensor-parallel setup now drafts three tokens a round instead of two. On the installed pair the assistant's first and second drafts were accepted 87% and 84% of the time, so a third proposal adds about 0.6 tokens a round for one more draft step; the verify window stays bound by one weight pass. Every emitted token is still the target's own choice.
