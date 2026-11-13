### Qwen constraint spans

- Add default-off `DARKBLOOM_CONSTRAINT_SPANS` support for eligible strict-auto Qwen tool requests: ordinary reasoning and content may draft, with marker boundaries and complete call arguments still protected.
- Preserve existing grammar admission, masks and off behavior. Provider integration and JSON support remain under qualification; no full-model speedup is claimed.
