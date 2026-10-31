### A running cluster service answers after the Macs pair again

- When the two Macs pair again while their cluster services run (`darkbloom cluster` or `darkbloom cluster pair`), each service starts its setup and control-lease listeners again with the new pairing within about 5 seconds. They used to keep the earlier pairing's key until the service restarted, so the other Mac's leases and its "Reading both Macs over the cable" step were refused (`refused (handshakeRejected)`). The service log says `this Mac's pairing changed (<cluster label>): answering the paired Mac with the new one`.
- A Mac left with no pairing stops answering over the cable. A pairing store that cannot be read leaves the listeners as they are.
- A Mac that paired again under a new Secure Enclave key of its own drops its earlier control state, as it already did when the other Mac's key changed.
- A cluster service started by an earlier release keeps the earlier behavior until it restarts (log out and back in, or `darkbloom cluster stop` and then `darkbloom cluster`).
