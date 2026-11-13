### The loop guard covers image and video requests

- Image and video requests on one Mac to Gemma 4, Qwen 3.5/3.6/3.8, Qwen
  Flash-Next and GLM-5.3 now get the text path's loop guard: a media answer
  that repeats one block verbatim ends as `length` instead of running to its
  output cap. MiMo's and Super's media and the pairs' media routes are
  unchanged.
- For Gemma 4, a repeating thought on an image or video request ends the
  thought and the model answers, over the same media input (exit-thinking).
- On OpenRouter's VGI-Bench rerun of 11-13, 117 of 257 served Gemma video
  answers ran to the 117,8xx-token cap and 116 of those returned no content;
  the median served answer was 110K tokens long (27 minutes).
