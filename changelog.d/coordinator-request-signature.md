### The provider can read an optional signature on inference requests (not used yet)

- The provider reads an optional `coordinator_signature` field on `inference_request` and can verify it in a build that pins a signing key. No build pins one, so every request is served exactly as before.
