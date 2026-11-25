### Sealed terminal fields

- The provider sends a response's finish reason, matched stop sequence,
  response hash and signature only inside the sealed usage, and never their
  clear copies on `inference_complete`.
- A usage that cannot be sealed ends the request with `encryption_failure`.
- The clear profile reports a stop-sequence finish as `stop`.
- The registration carries `terminal_fields_sealed: 1`.
- A coordinator reads these fields by opening the sealed usage, so it must do
  that before providers on this release connect.
