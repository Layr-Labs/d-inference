### Media the model's processor refuses answers 400 on one Mac and on a pair

- An image or video the model's processor refuses now returns HTTP 400 `Invalid media input.` (`invalid_media`) on one Mac and on a two-Mac pair: for Qwen 3.5 and 3.8 a side below 32 pixels (a 16×16 PNG, for one; the processor does not upscale it) or an aspect ratio above 200:1, a video without a decodable track, or more media than a processor takes. It returned the retryable 503 capacity answer, so the coordinator tried other providers that refuse it the same way.
