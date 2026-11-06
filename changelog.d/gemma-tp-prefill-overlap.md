### Gemma 4 tensor-parallel prefill can overlap its link traffic with compute (off by default)

- A Gemma 4 pair in tensor parallel can now split each prompt chunk's work after attention into parts, so one part's results cross the cable while the next part computes. Every value and token is unchanged. On two M5 Ultras, 4 parts prefilled a 9,651-token prompt at 1,196–1,208 tok/s instead of 1,064 (+13 %), with identical output. It stays off by default; the bench tool takes `--prompt-parts`.
