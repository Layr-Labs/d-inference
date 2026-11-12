### Gemma 4 tensor parallel serves 2 requests at once where both Macs' memory holds them

- A Gemma 4 26B pair in tensor parallel served one request at a time. Through Darkbloom, every request beyond the
  one it served was turned away as "at capacity".
- Now the setup sizes the QAT 4-bit pair the way it sizes Qwen 3.8 27B's tensor parallel: it serves 2 requests at
  once where both Macs can hold them now beside the model. Each request after the first is charged everything one
  request holds at the standard request (32,768 prompt plus 32,768 output tokens), about 2.6 GB on each Mac, and each
  Mac reserves that width when the model loads, the planner counting that reservation while the model is read.
- Why 2: on two M5 Ultras every request got its own tokens at 2, 4 and 8 at once, but each request was served fastest
  at 2 (77 tok/s each and 95.5 in all, against 48.5 and 96.2 at 4). The 8-bit model still serves one request at a
  time; nothing has qualified its lanes yet.
- The setup screen and the number the pair reports to Darkbloom are the same width. Where only one request fits,
  the pair saves no width and serves one request at a time, as before.
- Each request still gets exactly the tokens it gets alone. A request cancelled or refused for memory ends alone,
  and the others keep running.
