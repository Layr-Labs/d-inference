### The loop guard covers image and video requests

- One Mac's image and video requests now get the text path's loop guard: a
  media answer that repeats one block verbatim ends as `length` instead of
  running to its output cap.
- For Gemma 4, a repeating thought on an image or video request ends the
  thought and the model answers, over the same media input (exit-thinking).
- On OpenRouter's VGI-Bench rerun of 11-13, 117 of 257 Gemma video answers
  ran their thought to the 117,8xx-token cap (median 103K tokens, 27 minutes)
  and answered nothing.
