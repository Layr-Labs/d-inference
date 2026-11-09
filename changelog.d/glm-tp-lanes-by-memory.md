### GLM-5.3-Flash tensor parallel serves as many requests at once as both Macs' memory holds

- A GLM-5.3-Flash pair in tensor parallel served up to eight requests at once on any two Macs. Its load checked
  memory for one request only, so a pair with room for fewer still told Darkbloom eight.
- Now the setup sizes GLM the way it sizes Gemma 4 26B and Qwen 3.8 27B in tensor parallel. It saves the widest of 8,
  6, 4 or 2 requests at once that both Macs can hold now beside the model, and each Mac reserves that width when the
  model loads. Each request after the first is charged what it adds at the standard request (32,768 prompt plus
  32,768 output tokens): about 9.7 GB.
- The setup screen and the number the pair reports to Darkbloom are the same width. Where only one request fits, the
  pair saves no width and serves one request at a time.
- A pair set up before this version is planned again by itself after the update, as after every Darkbloom update,
  and saves its width then.
- Each request still gets exactly the tokens it gets alone.
