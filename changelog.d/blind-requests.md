### Blind requests

- The provider can serve requests whose body the client sealed to it and the
  coordinator relayed unopened, under terms the coordinator signs
  (`inference_request.blind` and `signed_request`).
- It checks the signature, its place among the keys the client sealed to, the
  client's binding of the body, the model, the output and prompt bounds and
  the declared traits, and holds generation to the signed output bound.
- A refused request gets `blind_refused` with a refusal signed by the Mac's
  Secure Enclave key. A refusal that follows from the opened body names only
  `content_unsupported`, never which part, control or length.
- No build pins a coordinator key for blind requests yet, so no provider
  registers `blind_protocol` until one does.
