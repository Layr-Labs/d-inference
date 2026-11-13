### GLM JSON answers: an optional release of schema misses

- A GLM-5.3-Flash JSON `response_format` answer is checked before it is exposed. One that parses as JSON but misses the caller's schema has been refused with a 422 after the streamed reasoning; it still is by default.
- `DARKBLOOM_GLM_JSON_SCHEMA_MISS=release` exposes it instead, as the normalized JSON (fences and surrounding prose removed), so the caller's own validator judges it. Output that is not a complete JSON value is refused either way.
