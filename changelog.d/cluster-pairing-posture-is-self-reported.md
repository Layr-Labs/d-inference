### Pairing shows the other Mac's posture as reported, not verified

- `darkbloom cluster pair` showed the other Mac's SIP, Secure Boot and
  sealed-volume status, and its "Secure Enclave key pin", as facts beside the
  pairing code. They come from an attestation the other Mac signs with the key
  it pairs with, which proves possession of that key, not that a Secure Enclave
  holds it or how the Mac booted. The screen now marks the posture "reported by
  the other Mac, not verified" and calls the pin a key pin; the "Paired" summary,
  the setup wizard and the proof-failure message no longer call the other Mac's
  key a Secure Enclave key either. What is checked and stored is unchanged.
