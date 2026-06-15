# Hardware Support

Providers run on Apple Silicon Macs (M1 or later). Minimum requirements depend
on the model being served.

## Supported chips

| Chip | Memory | Bandwidth | Typical models |
|---|---|---|---|
| M1 | 8–16 GB | 68 GB/s | 3B–8B |
| M1 Pro/Max | 16–64 GB | 200–400 GB/s | 8B–33B |
| M2 Pro/Max | 16–96 GB | 200–400 GB/s | 8B–70B |
| M3 Pro/Max | 18–128 GB | 150–400 GB/s | 8B–122B |
| M3 Ultra | 96–256 GB | 819 GB/s | 8B–230B |
| M4 Pro/Max | 24–128 GB | 273–546 GB/s | 8B–122B |

These are guidelines, not guarantees. A provider's `ensureModelLoaded` requires
`estimatedMemoryGb * 3.0` headroom (`provider-swift/Sources/ProviderCore/...`).
The coordinator's `freeMemoryAdmits` check is less conservative, so a model the
coordinator admits can still fail to load on the provider.

## macOS requirements

- macOS 15 or later is the current minimum target.
- System Integrity Protection (SIP) must be enabled.
- Secure Boot must be set to Full (for `hardware` trust).
- A logged-in GUI Aqua session is required for APNs code-identity attestation.

## Networking

Providers need outbound HTTPS/WebSocket to the coordinator. No inbound port
forwarding is required because the provider initiates the WebSocket.
