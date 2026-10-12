### Provider endpoint resumption

- Add protocol-1 endpoint-custody responses for same-process reconnects, using a fresh nonce per socket and the existing in-memory encryption key. Requires the matching platform implementation; does not grant local trust or extend Apple proof lifetimes.
- Make `darkbloom logout` drain and stop the provider before removing credentials, and attempt revocation of the saved provider token. Report unconfirmed remote revocation explicitly.
- Bind saved tokens to their issuer and roll back failed credential saves. Preserve revocation URL authority, ignore unbound stale PID occupants, and allow local logout when configuration is malformed.
- Enforce resume control-frame limits before decoding, while preserving large ordinary inference frames.
- Add an isolated signed-app diagnostic for native loaded-engine endpoint resumption. Reject runs that exit before their completion marker; align the retained threat model with the authoritative platform policy.
