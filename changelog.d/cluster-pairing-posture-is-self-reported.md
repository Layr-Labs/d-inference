### Pairing shows the other Mac's posture as reported, not verified

- During `darkbloom cluster pair` and cluster onboarding, the other Mac's SIP,
  Secure Boot and sealed-volume status, and its "Secure Enclave key pin", were
  shown as facts. They come from an attestation the other Mac signs with the key
  it pairs with, which proves possession of that key, not that a Secure Enclave
  holds it or how the Mac booted. The screen now marks the posture "reported by
  the other Mac, not verified" and calls the pin a key pin. What is checked and
  stored is unchanged.
