### Gemma 4 tensor-parallel prefill is nearly twice as fast

- A Gemma 4 pair in tensor parallel computed each prompt chunk's experts one token at a time on each Mac. Each chunk's experts now run together, with every value unchanged. On two M5 Ultras a 9,651-token prompt prefilled at 1,066 tok/s instead of 569, with identical output.
