### Live model switch with a custom model cache

- `darkbloom switch` now scans the `model_cache_directory` set in `provider.toml`. With a non-default directory it previously rejected every local model as missing or unsupported, and its picker listed installed models as downloads, although the running provider served them from that directory.
