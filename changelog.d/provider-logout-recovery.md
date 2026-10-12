### Logout and native qualification recovery

- Bind the saved token to its issuer at login and use that issuer for revocation, including after the provider stops. Never guess from changed configuration; legacy tokens without issuer metadata are removed locally with a warning.
- Stop the provider and remove local credentials even if the fallback configuration is malformed; report remote revocation as unconfirmed.
- Reject native qualification runs whose serving loop exits before the completion marker, and keep the retained threat model aligned with platform serving and receipt policy.
- Enforce the resume control-frame limit before decoding its payload, reject UTF-16/32 JSON that could bypass the UTF-8 gate, and preserve the original coordinator authority when constructing credential-revocation requests.
