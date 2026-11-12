### A Gemma 4 pipeline checks its whole number of requests at load, and serves one at a time without one

- A Gemma 4 pipeline set up by `darkbloom cluster` still reads each prompt with one chunk of lookahead and serves one
  request at a time. Serving several at once needs it to read each prompt one chunk at a time, and on two M5 Ultras a
  long prompt alone then started its answer about 1.9 times later, so the setup keeps the lookahead.
- A pipeline whose setup saves one-chunk-at-a-time reading and a number of requests at once (2, 4 or 8) serves that
  many. Each Mac now checks at load that the whole number fits beside the model, each request charged its whole state
  at the standard request (32,768 prompt plus 32,768 output tokens), and refuses the load if it does not: "Resident
  load refused: N requests at once, each of C context tokens, do not fit on rank R now". Before, the load checked one
  request. A Qwen 3.5 or Gemma 4 pipeline widened automatically on a local pair is checked the same way.
- A pipeline set up to read prompts a chunk at a time without a saved number now serves one request at a time. Before,
  it served four, which nothing had checked its memory for.
- Each request still gets exactly the tokens it gets alone. A request cancelled or refused for memory ends alone, and
  the others keep running.
