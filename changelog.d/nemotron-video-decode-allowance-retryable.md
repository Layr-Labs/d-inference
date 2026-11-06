### A Nemotron Super video that decodes too slowly on a provider is retried elsewhere

- When the wait on the video decoder outlasts its decode allowance (5 s, then 2 ms a frame and 4 ns a coded pixel, at most 120 s of wall time), as on a slow or loaded Mac, Nemotron Super now refuses the request as a retryable 503 (failure code `capacity`), and the coordinator can send it to another provider. Before, the provider refused the valid video as `invalid_media` (400).
- The video's own limits (frame size, frame grid, source frames, control markers, decoded pixels) are still `invalid_media` (400).
