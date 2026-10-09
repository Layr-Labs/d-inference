# Darkbloom Provider Documentation

> Last updated: 2026-10-09

This repository documents the Swift provider, local native inference, landing,
and retained console snapshot. New backend, console and admin development and
backend operating guides belong to
[the platform](https://github.com/Layr-Labs/darkbloom-platform/tree/48a198c71a2d30feec5597bacf1101120f7f955d/docs).

## Operate A Provider

- [Installation](provider/installation.md) and [quickstart](provider/quickstart.md)
- [CLI reference](provider/cli-reference.md) and [configuration](reference/configuration.md)
- [Hardware requirements](provider/hardware-requirements.md)
- [Cache storage and daily writes](provider/cache-storage.md)
- [Attestation](provider/attestation.md) and [troubleshooting](provider/troubleshooting.md)
- [Local direct mode](provider/direct-mode.md) and [network self-route](provider/self-route.md)
- [Fan control](provider/fan-control.md) and [beta features](provider/beta-features.md)

## Understand And Develop

- [Provider architecture](architecture/overview.md) and [architecture index](architecture/README.md)
- [Encryption, endpoint visibility and cache-storage limits](architecture/security/encryption.md)
- [Reference index](reference/README.md) and [glossary](glossary.md)
- [Ownership and navigation](developer/navigation.md)
- [Build](developer/build.md) and [test/qualification boundaries](developer/test.md)
- [MiMo public fixtures](developer/mimo-prompt-fixtures.md)
- [Serving-performance qualification](developer/serving-performance-qualification.md)
- [PR stacks](developer/pull-requests.md) and [threat-review tooling](developer/threat-model-review.md)
- [Landing application](../landing/README.md)
- [Retained console architecture and hosting configuration](architecture/components/console-ui.md)

Public golden vectors validate fixed expected behavior. They do not execute the
private platform implementation or establish live routing, real Apple
attestation, full-model GPU qualification or service cutover.

## Publish And Review

- [Publication operations](operations/README.md): approved release/model API actions only
- [Provider/native evidence and original archives](reports/README.md)
- [Design records](design/README.md) and [historical-source navigation](developer/historical-references.md)
- [Machine-readable provider threat model](threat-model.yaml)
- [Documentation rules](AGENTS.md)
- [Published privacy policy](legal/privacy-policy.md) and [terms](legal/terms-of-service.md)

Frozen records are retained unchanged or retired with their inbound dependency
closure. Raw retained evidence is not reinterpreted as a new successful run.
