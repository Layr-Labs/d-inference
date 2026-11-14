### Inline video decided by its bytes

- An inline video (`video_url` with a `data:` URI) is opened when its bytes are an MP4 or QuickTime file, whatever its label: `video/mov`, `video/x-m4v`, `application/octet-stream`, a `codecs` parameter or no media type. Every Mac refused these with 400 `invalid_media`; OpenRouter documents `video/mov` among its video formats.
- An inline video in another container (WebM, Matroska, an MPEG stream, AVI, Ogg) is refused as `unsupported_media` (415 through the coordinator) instead of `invalid_media`; a damaged MP4 or QuickTime file is still `invalid_media`.
- An inline video payload that is not base64 (no `;base64` parameter, matched in any case) is a malformed URI (`invalid_media`).
