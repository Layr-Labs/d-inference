### Gemma 4 tensor-parallel prefill can overlap its link traffic with compute (off by default)

- A Gemma 4 pair in tensor parallel can now split each prompt chunk's work after attention into parts, so one part's results cross the cable while the next part computes. Every value and token is unchanged. It stays off until it is measured on a pair; the bench tool takes `--prompt-parts`.
