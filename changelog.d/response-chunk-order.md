### Response chunks are numbered, and the usage is sealed after them

- The provider seals each response chunk of a request under a nonce that numbers it (a prefix drawn for the request, then the chunk's number from 0), so the coordinator can check that it received every chunk once and in order.
- `inference_complete` also carries `encrypted_usage`: the usage and the number of chunks, sealed after the last chunk. The plaintext `usage` is unchanged, so coordinators that read only it work as before.
