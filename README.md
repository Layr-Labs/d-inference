# Darkbloom Provider

Darkbloom's Apple Silicon provider, native inference runtime integrations, and
marketing site live here, alongside the retained console source snapshot and
its existing build/test/hosting configuration. The provider runs models locally with MLX and can
connect to the Darkbloom network or serve a local OpenAI-compatible API.

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
The existing `console-ui/` snapshot remains locally available; retaining it does
not transfer new development ownership back from the platform. Device-local Swift APIs
remain provider code. Check `git remote -v` and the intended diff before pushing.

Source ownership does not grant deployment authority. Infrastructure, hosting
and traffic changes require specific human approval. Release/model registration
remains an external API operation.

## Run A Provider

Start with [installation](docs/provider/installation.md), then
[quickstart](docs/provider/quickstart.md). Use [direct mode](docs/provider/direct-mode.md)
for local inference, [hardware requirements](docs/provider/hardware-requirements.md)
for model fit, and [cache storage](docs/provider/cache-storage.md) for encrypted
SSD storage and daily write limits.

The provider is the plaintext inference endpoint. Network encryption does not
hide prompts from that process or from the coordinator's transient request
processing. See the [encryption and storage trust model](docs/architecture/security/encryption.md)
and [provider attestation](docs/provider/attestation.md); do not infer security
guarantees from a repository split.

## Develop

Tool versions are in `mise.toml`; supported commands are in `Makefile`:

```bash
mise install
make provider-build
make provider-test
make ui-install ui-lint ui-test ui-build
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
| `console-ui/` | Retained console source and build/test/hosting configuration; new development belongs to the platform |
| `coordinator/tests/protocol/testdata/` | Retained console-test JSON fixtures only |
| `fixtures/` | Public, revision-bound test inputs |
| `scripts/` | Provider builds, native qualification, install and publication helpers |
| `docs/` | Provider/native explanations, references, operations and historical evidence |

See the [documentation index](docs/README.md) and retained
[console architecture](docs/architecture/components/console-ui.md). Platform API and consumer guides
are maintained in the [platform documentation](https://github.com/Layr-Labs/darkbloom-platform/tree/48a198c71a2d30feec5597bacf1101120f7f955d/docs).
Existing [changelog history](CHANGELOG.md) remains a record of work before and
after the ownership split, not evidence of a new release or deployment.

## License

See [LICENSE](LICENSE) and [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md). Published
[privacy](docs/legal/privacy-policy.md) and [terms](docs/legal/terms-of-service.md)
remain unchanged by source cleanup.
