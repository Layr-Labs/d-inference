### Signed usage for blind requests

- A served blind request's `inference_complete` carries `blind_usage`: its
  usage statement, signed by the Mac's Secure Enclave key over the signed
  terms, the usage, how it finished, and digests of the frames and the sealed
  usage it sent.
- A usage that cannot be signed ends the request with `encryption_failure`.
