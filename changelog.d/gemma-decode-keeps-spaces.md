### Gemma 4 text keeps its spaces before punctuation

- Gemma 4 replies, reasoning and tool arguments no longer lose the space before `.`, `,`, `?` and `!`, or repeat a quote. `git add .` came back as `git add.`, `bash ./run.sh` as `bash./run.sh`, `x != y` as `x!= y`, and, when streamed, `role = 'start'` as `role = ''start'`.
- Gemma 4's published `tokenizer_config.json` omits `clean_up_tokenization_spaces`, and the Swift tokenizer library reads a missing key as cleanup on, where Python Transformers reads it as off. The provider now resolves a missing key to off in memory for every model. An explicit Boolean is kept.
- Token IDs, sampling, model state and cache keys do not change. Only the text decoded from the same tokens does. Stop strings match the text as spelled: one with a space before punctuation can now match, and one that matched only the cleaned text (`add.` for `add .`) no longer does.
