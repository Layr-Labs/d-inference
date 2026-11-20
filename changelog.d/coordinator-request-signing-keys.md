### Coordinator request-signing keys

- Production and dev builds pin their coordinator's request-signing public key.
  A request that carries a coordinator signature is served only if the
  signature verifies for this Mac, is within 300 s of its clock and has not been
  served already. A request without one is still served: no build requires a
  signature yet.
