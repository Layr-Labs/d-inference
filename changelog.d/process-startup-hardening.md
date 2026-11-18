### Process startup hardening

- Every Darkbloom executable (the provider, its enclave and fan helpers, and the cluster worker and planner) now applies additional start-up hardening before it creates a key, reads a request or loads a model.
- `darkbloom doctor` shows a new `startup hardening` check. If the hardening can't be applied, the Mac does not serve and only diagnostics run.
