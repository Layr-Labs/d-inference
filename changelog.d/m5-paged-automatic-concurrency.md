### M5 paged serving concurrency

- Serve up to 8 concurrent requests per model by default on M5 Pro, M5 Max and M5 Ultra for models that the default `auto` backend selects for paged KV, when `engine_v2_max_concurrent` is absent from `provider.toml`. Other chips, contiguous models, models paged only by an explicit backend or live KV quantization setting, explicit global or per-model concurrency settings (including a `4` written by older releases) and reviewed profiles are unchanged; the coordinator's per-model quality cap still bounds admission.
- Fall back from that width to the configured width under Low Power Mode or thermal pressure, as reviewed profiles already do. `darkbloom status` and `doctor` describe the M5 default.
