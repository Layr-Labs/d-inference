### Coordinator connection check

- Once a TLS connection to the coordinator is ready, the provider checks that
  its host is the build's coordinator host and that its certificate chains to
  one of the certificate authorities the coordinator's certificates come from,
  and logs a warning for each difference. The connection continues either way.
