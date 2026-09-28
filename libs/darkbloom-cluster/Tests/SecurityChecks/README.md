# Authenticated record CPU checks

These checks compile the current `DarkbloomClusterSecurity` sources with Swift 6
and CryptoKit. They require macOS and Xcode command-line tools; no model, MLX
build, network connection or peer is used.

From the repository root, choose a new output directory:

```sh
python3 -B libs/darkbloom-cluster/Tests/SecurityChecks/run.py --output /tmp/darkbloom-record-checks
```

The codec cases compare both directions against fixed vectors generated with
Python HMAC/HKDF and OpenSSL EVP AES-GCM through `ctypes`. They cover authenticated
context, ciphertext tampering, framing bounds, replay, sequence and byte limits,
concurrent calls and invalidation. `Codec/generate_vectors.py` records how to
regenerate the public test vectors; it is not needed to run the checks.

The adapter cases exercise exact single-frame transfers and bounded variable
controls through an in-memory byte endpoint. They verify that authentication and
cancellation checks precede payload publication, blocked operations remain owned,
failures poison the channel, and record/frame budgets are checked without integer
overflow. They do not qualify RDMA padding, native array reconstruction, peer
authorization, key establishment or native memory admission.

Each compiler is limited to two jobs and 60 seconds; each executable has a
10-second bound. The runner retains source identities, logs and owned-child
cleanup receipts, including failures. Run native and model checks separately.
