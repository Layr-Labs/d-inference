# Darkbloom Provider

Darkbloom's Apple Silicon provider, native inference runtime integrations, and
marketing site live here. The provider runs models locally with MLX and can
connect to the Darkbloom network or serve a local OpenAI-compatible API.

## Use Your Mac's Models

Put OpenCode (or Hermes) on this Mac's own models:

```bash
curl -fsSL https://api.darkbloom.dev/install.sh | bash
exec $SHELL -l                    # or open a new Terminal window, so your shell finds darkbloom
darkbloom --opencode              # or --hermes
```

It asks how this Mac serves: **Only me**, **Darkbloom network** or
**Both, me first**. Press Enter for Both, me first. Every choice asks which
models to serve and serves them in the background; with Only me or Both, me
first, `--opencode` sets OpenCode up. Darkbloom network gives OpenCode no
address on this Mac. Then, in OpenCode, `/models` → Darkbloom. Two Macs: run
`darkbloom cluster` on each, then `darkbloom --opencode` on the leading Mac.

<!-- pending LS-3: in a pair, start with opencode on either Mac. -->

The [quickstart](docs/provider/quickstart.md) walks through it, and
[Use your Mac yourself, first](docs/provider/local-first.md) says what each
choice runs, costs and earns. See also [the local API](docs/provider/direct-mode.md)
for other OpenAI clients, [installation](docs/provider/installation.md),
[hardware requirements](docs/provider/hardware-requirements.md) for model fit,
and [cache storage](docs/provider/cache-storage.md) for encrypted SSD storage
and daily write limits. To have an AI agent set up serving the Darkbloom
network, point it at the [agent setup prompt](docs/provider/agent-setup.md).

The provider is the plaintext inference endpoint. Network encryption does not
hide prompts from that process or from the coordinator's transient request
processing. See the [encryption and storage trust model](docs/architecture/security/encryption.md)
and [provider attestation](docs/provider/attestation.md); do not infer security
guarantees from a repository split.

## Repository Ownership

Use sibling checkouts, never one repository nested inside the other:

```text
Darkbloom/
  d-inference/          Swift provider, local native APIs, MLX and landing
  darkbloom-platform/   Coordinator, prompt sidecar, consumer console and admin
```

Centralized backend, console and admin code belongs exclusively in
[darkbloom-platform](https://github.com/Layr-Labs/darkbloom-platform/tree/48a198c71a2d30feec5597bacf1101120f7f955d).
Never implement, commit, push or upload new backend, console or admin code here.
Device-local Swift APIs remain provider code. Check `git remote -v` and the
intended diff before pushing.

Source ownership does not grant deployment authority. Infrastructure, hosting
and traffic changes require specific human approval. Release/model registration
remains an external API operation.

## Develop

Tool versions are in `mise.toml`; supported commands are in `Makefile`:

```bash
mise install
make provider-build
make provider-test
make landing
make docs-check
```

Provider builds require Apple Silicon, the documented Xcode toolchain, and the
recursive MLX dependencies. See [build](docs/developer/build.md),
[test](docs/developer/test.md), [navigation](docs/developer/navigation.md), and
[contribution rules](CONTRIBUTING.md). Public golden vectors check fixed expected
behavior; they are not private cross-implementation qualification or live fleet
evidence.

## Layout

| Path | Ownership |
|---|---|
| `provider-swift/` | CLI, on-device services, inference, security and tests |
| `libs/` | Pinned native MLX dependencies |
| `landing/` | Independent Next.js marketing site and its API routes |
| `fixtures/` | Public, revision-bound test inputs |
| `scripts/` | Provider builds, native qualification, install and publication helpers |
| `docs/` | Provider/native explanations, references, operations and historical evidence |

See the [documentation index](docs/README.md). Console architecture, platform API
and consumer guides are maintained in the [platform documentation](https://github.com/Layr-Labs/darkbloom-platform/tree/48a198c71a2d30feec5597bacf1101120f7f955d/docs).
Existing [changelog history](CHANGELOG.md) remains a record of work before and
after the ownership split, not evidence of a new release or deployment.

## License

See [LICENSE](LICENSE) and [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md). Published
[privacy](docs/legal/privacy-policy.md) and [terms](docs/legal/terms-of-service.md)
remain unchanged by source cleanup.
