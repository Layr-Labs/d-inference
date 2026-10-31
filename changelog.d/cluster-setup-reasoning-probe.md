### Cluster setup respects model reasoning defaults

- Cluster setup tests a response using each model's default reasoning controls, so GLM-5.3 Flash no longer rejects the generic probe because it sends a binary thinking override. Reasoning-only output remains visible when the test token budget expires.
