### Inference requests can carry the coordinator's signature

- The provider reads an optional `coordinator_signature` on `inference_request`: the coordinator's Ed25519 signature over the request id, the service reservation, the provider's own public key, the model, the sealed body and the cache fields sent beside it, with the time it was sent.
- A build that pins a coordinator signing key serves a signed request only if the signature verifies for this provider and is at most five minutes from the Mac's clock either way; it refuses the request otherwise and releases its reservation. The same signed request is served once; a second copy gets no answer. A build can also be set to refuse requests that carry no signature.
- No key is pinned yet, so providers serve every request exactly as before, and coordinators that do not sign keep working.
