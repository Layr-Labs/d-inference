# Try the Ollama companion POC

> Last updated: 2026-09-21 · commit `ce809b792`

Use Darkbloom Connect to discover an existing Ollama library and set up a
separate signed Darkbloom worker. This experimental app does not route customer
prompts into Ollama or convert Ollama weights.

## Prerequisites

- Apple Silicon Mac, Xcode command-line tools with Swift 6, and this checkout.
- macOS 14 or later to inspect the app; new App Attest onboarding requires
  macOS 27 or later and coordinator approval.
- Ollama running on its default loopback port, or an existing
  `~/.ollama/models/manifests` library. Custom Ollama hosts and directories are
  intentionally unsupported in the POC.
- The official signed Darkbloom provider installed at
  `~/.darkbloom/bin/darkbloom` before continuing setup. The companion never
  accepts a user-supplied executable or a development provider as a substitute.

## Steps

1. Build and open the companion from the repository root:

   ```sh
   ./experiments/ollama-connect/script/build_and_run.sh --verify
   ```

   The script creates `experiments/ollama-connect/dist/DarkbloomConnect.app`.
   Its ad hoc development signature is not a provider credential. Opening the
   app performs metadata reads only; it does not start or stop inference.
   Rebuilding stops only a companion launched from this worktree before
   replacing its executable; it never stops the provider.

2. Review **Model library**. Ollama inventory is read-only, unverified metadata.
   It never establishes artifact compatibility or serving permission.

3. On **Connection**, install the official provider if absent, then choose
   **Link account**. The signed CLI opens its device-login flow in Terminal and
   the browser. The companion never reads the account credential.

4. Choose a network model from the current coordinator catalog and select
   **Prepare model**. This opens the signed provider's download command in
   Terminal. It may download a separate MLX artifact; Ollama's files are neither
   copied nor modified. The provider verifies its manifest and weights.

5. Select **Start contributing**, read the service/terms notice, and continue
   in Terminal. This runs the signed provider's normal background-service
   startup. The coordinator's runtime, memory, model and App Attest checks
   still decide eligibility. If a provider is already running, the POC shows
   its status and does not offer replacement/start controls.

6. Review **Privacy & verification**. Authorization appears only while the
   signed running process, current local connection evidence, and public
   coordinator response agree. This UI is not a serving credential.

## Verify

```sh
swift test --package-path experiments/ollama-connect
python3 experiments/ollama-connect/script/test_transport.py
swift run --package-path experiments/ollama-connect connect-probe
cd coordinator
go test -race ./registry -run 'TestOllamaBridge|TestAppAttest' -count=1
```

The real-socket test requires port 11434 to be free and refuses to displace
Ollama. It uses a **hostile test fixture**, not an installed Ollama server, and
checks redirects, invalid/oversized responses, credential-free GET requests,
and the absence of generation/chat traffic. The probe reads live metadata and
does not issue inference. The [security explanation](../architecture/security/ollama-connect.md)
separates those results from real model and signed serving qualification.

The first POC validation used the installed signed provider for
`TestIntegration_E2EEncryptionCorrectness` with a cached
`mlx-community/Qwen3.5-0.8B-MLX-4bit` fixture: it returned `4` through an isolated
coordinator's encrypted provider transport. That harness supplies synthetic
trust; it is **not** a fresh production App Attest qualification. Independently,
the companion observed the existing production worker's current App Attest
authorization via the public coordinator endpoint without changing it.

Qwen 3.8 27B is offered only from the live catalog. The existing EigenLabs
artifact's M5/NAX requirements remain unchanged; an M4 Mac cannot become
eligible through this companion. The POC did not qualify that model on new
hardware or attest an Ollama runtime.

## Troubleshooting

- **Ollama offline:** the app can discover saved manifests without starting
  Ollama. It does not claim that a saved model is loaded or compatible.
- **Catalog unavailable:** retry; setup cannot use a stale catalog fallback.
- **Verification pending:** use provider diagnostics. Expired or missing
  evidence stays unconfirmed; no MDM fallback or serving override is added.
- **Existing worker found:** manage it with the existing CLI or provider
  dashboard. Do not use this POC to replace an active service.

## Related

- [Provider authorization](../reference/provider-authorization.md)
- [CLI reference](cli-reference.md)
- [Ollama companion security](../architecture/security/ollama-connect.md)
