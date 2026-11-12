### Qwen3.5-9B takes up to 64 images a request

- A Qwen3.5-9B request may carry up to 64 inline images; every model had a cap of 16. An OpenRouter client sends the 9B 17–61 images a request (mostly 60, about 7.4 MB), and every Mac refused each one at its 17th image with 413 `media_too_large`, about 3,900 requests an hour. Every other model keeps 16, and `DARKBLOOM_MAX_IMAGES_PER_REQUEST`, when set, is still one cap for every model.
- The memory guards are unchanged: the 384-megapixel request total and the 25 MiB per-image limit still bound decoding, the vision tower still runs one image at a time, and the media memory gate still reserves the decoded images and 1,024 KV tokens per image before any work.
- A media request that this Mac's memory can't hold right now is refused as a retryable 503 with the reason `media_memory_unavailable` (it was `capacity_busy`), so Darkbloom sends it to another Mac without counting this Mac's capacity as full.
