### Gemma 4 tensor parallel serves several requests at once, as many as both Macs' memory holds

- A Gemma 4 26B pair in tensor parallel served one request at a time. Through Darkbloom, every request beyond the
  one it served was turned away as "at capacity".
- Now the setup sizes the pair the way it sizes Qwen 3.8 27B's tensor parallel. It saves the widest of 8, 6, 4 or 2
  requests at once that both Macs can hold now beside the model. Each request after the first is charged everything
  one request holds at the standard request (32,768 prompt plus 32,768 output tokens), about 2.6 GB on each Mac, and
  each Mac reserves that width when the model loads.
- The setup screen and the number the pair reports to Darkbloom are the same width. Where only one request fits,
  the pair saves no width and serves one request at a time, as before.
- Each request still gets exactly the tokens it gets alone. A request cancelled or refused for memory ends alone,
  and the others keep running.
