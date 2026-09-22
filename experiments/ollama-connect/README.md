# Darkbloom Connect — Ollama companion POC

A native macOS companion for existing Ollama users. It discovers local model
metadata, offers the live Darkbloom model catalog, validates the installed
provider's signing identity and running process, and corroborates App Attest
status against the coordinator. Setup continues in the existing signed CLI.

**This is an onboarding integration, not an Ollama inference proxy.** Network
inference remains in the existing signed Darkbloom worker. No GGUF conversion,
Ollama engine reuse, or new attestation credential is introduced.

```sh
./experiments/ollama-connect/script/build_and_run.sh --verify
swift test --package-path experiments/ollama-connect
python3 experiments/ollama-connect/script/test_transport.py
```

The app is staged at `dist/DarkbloomConnect.app` beneath this package. The local
build is ad hoc signed and is **not** an attested provider. It must find the
separately installed Developer ID provider before enabling setup commands.
The Codex Run action runs the same build script.

- [Setup and verification](../../docs/provider/ollama-connect.md)
- [Security boundary and limits](../../docs/architecture/security/ollama-connect.md)

Source layout: `ConnectCore` owns bounded metadata reads, signature/process
checks, catalog validation, evidence expiry and the closed setup command set;
`DarkbloomConnect` owns SwiftUI views and their store; `ConnectProbe` provides a
read-only JSON diagnostic. There are no package dependencies and no HTTP server
in the companion. Rendering `--export-preview <directory>` exports the app's
own views for visual QA; it does not capture the user's screen.
