### Sealed terminal fields

- For a coordinator that advertises `terminal_fields_sealed` on its connection,
  the provider seals a response's finish reason, matched stop sequence,
  response hash and signature inside the sealed usage, and leaves their clear
  copies off `inference_complete`.
- The registration carries `terminal_fields_sealed: 1`.
- Other coordinators get the clear copies, as before.
