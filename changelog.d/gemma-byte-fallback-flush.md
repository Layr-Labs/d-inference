### Gemma 4 replies keep characters outside its vocabulary

- A Gemma 4 reply that ended in a character its vocabulary writes as byte tokens, such as many newer emoji, rare CJK and most Hangul syllables, lost that character: `all zipped up 🗜` came back as `all zipped up `. A long reply could also corrupt such a character when streaming restarted its decode inside its bytes.
- The Swift tokenizer library releases byte tokens only when a later token arrives. The provider's tokenizer bridge now releases a trailing run itself.
- Token IDs, sampling, model state and cache keys do not change. Only the text decoded from the same tokens does. A reply cut inside a character by `max_tokens` now ends in U+FFFD instead of dropping it, and a byte token's `logprobs` text is U+FFFD or its ASCII character instead of empty.
