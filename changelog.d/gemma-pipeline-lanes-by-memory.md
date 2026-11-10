### A Gemma 4 pipeline serves several requests at once, as many as both Macs' memory holds

- A Gemma 4 26B pair set up as a pipeline served one request at a time. Through Darkbloom, every request beyond the
  one it served was turned away as "at capacity".
- Now the setup saves the widest of 8, 4 or 2 requests at once that both Macs can hold now beside the model. Each
  request after the first is charged its whole state at the standard request (32,768 prompt plus 32,768 output
  tokens) on both Macs, and each Mac checks at load that the whole width fits.
- The setup screen and the number the pair reports to Darkbloom are the same width.
- To serve several requests, the pipeline reads each prompt one chunk at a time. A long prompt alone therefore starts
  its answer later than before. Where only one request fits, the pair keeps the faster start and serves one request at
  a time, as before.
- A pipeline set up without a saved number of requests (typed by hand) now serves one request at a time. Before, one
  set up to read prompts a chunk at a time served four, which nothing had checked its memory for.
- Each request still gets exactly the tokens it gets alone. A request cancelled or refused for memory ends alone, and
  the others keep running.
