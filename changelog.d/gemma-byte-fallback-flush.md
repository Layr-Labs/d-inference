### Gemma 4 replies keep characters outside its vocabulary

- A Gemma 4 reply that ended in characters its vocabulary writes as byte tokens, such as many newer emoji, rare CJK and most Hangul syllables, lost all of them: `all zipped up 🗜` came back as `all zipped up `, and a reply made only of such characters came back empty. A long reply could also corrupt such a character when streaming restarted its decode inside its bytes.
- The Swift tokenizer library releases byte tokens only when a later token arrives. The provider's tokenizer bridge now releases a trailing run itself. `/detokenize` keeps it too.
- Token IDs, numeric logprobs, sampling and cache keys do not change, with one exception: a stop string that a trailing run completes now matches when the run completes, one token sooner, so `completion_tokens` can fall by one.
- A streamed reply's `logprobs` gains the entries of those tokens, which it used to drop. A byte token's `logprobs` text and `bytes` are U+FFFD or its ASCII character instead of empty, not the real byte. A reply cut inside a character by `max_tokens` now ends in U+FFFD instead of dropping it.
