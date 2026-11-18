### Process startup is hardened against inherited debugging handles

- Every Darkbloom executable (the provider, its enclave and fan helpers, and the cluster worker and planner) now clears any debugging handles it inherited from the program that started it, before it creates a key, reads a request or loads a model.
- `darkbloom doctor` shows this as a new `startup hardening` check. If macOS ever refuses, the Mac does not serve and only diagnostics run.
