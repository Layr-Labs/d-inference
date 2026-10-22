### Flint paged-only defaults

- Flint now loads on paged attention with the default provider configuration and never falls back to contiguous. An explicit contiguous selection, the paged kill switch or a paged construction failure refuses the load instead of serving the unqualified contiguous path.
- Flint now uses native KV and checkpoint precision even when the provider-wide checkpoint default is `balanced`; an explicit per-model or environment request for reduced precision is still refused.
