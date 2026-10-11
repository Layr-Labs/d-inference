### Provider endpoint resumption

- Add protocol-1 endpoint-custody responses for same-process reconnects, using a fresh nonce per socket and the existing in-memory encryption key. Requires the matching platform implementation; does not grant local trust or extend Apple proof lifetimes.
- Make `darkbloom logout` drain and stop the provider before removing credentials, and attempt revocation of the saved provider token. Report unconfirmed remote revocation explicitly.
