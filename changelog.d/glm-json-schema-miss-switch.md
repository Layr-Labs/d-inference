### GLM JSON answers: an optional release of schema misses

- A GLM-5.3-Flash JSON `response_format` answer is checked before it is exposed. One whose JSON value misses the caller's schema has been refused with a 422 after the streamed reasoning; it still is by default.
- `DARKBLOOM_GLM_JSON_SCHEMA_MISS=release` exposes that value instead when the model stopped by itself (fences and surrounding prose removed), so the caller's own validator judges it. Output with no complete JSON value, and output cut at `max_tokens`, are handled as before. It applies to streamed responses, which every coordinator request is; a non-streamed local API request still gets the service's own schema check.
