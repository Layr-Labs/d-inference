### Logout and native qualification recovery

- Revoke the saved token against the running provider's coordinator, including command-line overrides, rather than an unrelated configuration URL.
- Stop the provider and remove local credentials even if the fallback configuration is malformed; report remote revocation as unconfirmed.
- Reject native qualification runs whose serving loop exits before the completion marker, and keep the retained threat model aligned with platform serving and receipt policy.
- Enforce the resume control-frame limit before decoding its payload, reject UTF-16/32 JSON that could bypass the UTF-8 gate, and preserve the original coordinator authority when constructing credential-revocation requests.
