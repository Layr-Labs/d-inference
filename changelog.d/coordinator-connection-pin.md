### Coordinator connection check

- Once a TLS connection to the coordinator is ready, the provider compares the
  host with the build's coordinator host and the certificate chain with the
  certificate authorities the coordinator's certificates come from, and logs a
  difference. The connection continues either way.
