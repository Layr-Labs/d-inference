### Model switching uses the configured model cache

- `darkbloom switch` now finds local models in the provider's saved `[backend] model_cache_directory`, the same cache `start` and `serve` use. Before, it searched only the default Hugging Face hub and rejected models stored elsewhere as "missing or unsupported local model(s)".
