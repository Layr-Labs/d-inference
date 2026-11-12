### Nemotron 3.5 Super: an image that arrives while another image's answer is streaming waits for it instead of bouncing

- A Super Mac serves one image at a time. An image that arrived while another image's answer was streaming was refused at once with 429 `queue_full`, so the coordinator sent it elsewhere or, after three refusals, gave up. Such an image now waits for the slot, up to 3 s, and is served when the image ahead of it finishes. An image's answer usually ends about 2 s after it starts streaming.
- For Darkbloom requests the wait never spends the request's time limit for its first token. It stops early enough to leave room for this Mac's recent time to first token on images, and is skipped when no room is left.
- Only one request waits at a time, and a waiting request reserves no memory, so two images are never in memory at once. Text requests, and images arriving while a text answer or an image's prompt is still being processed, are still refused at once.
