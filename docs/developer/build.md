# Build The Provider, Retained Console And Landing

> Last updated: 2026-10-09

Build the provider, its source-matched native resources, and the independent
landing site from this repository. The existing console snapshot and its build,
lint, test and hosting configuration remain here; new console development belongs
to the platform. Backend, sidecar and admin builds belong to that sibling repository.

## Prerequisites

Use sibling `Darkbloom/d-inference` and `Darkbloom/darkbloom-platform` checkouts.
Verify your remote and branch first; do not upload backend code here.
Install the versions in `mise.toml` and initialize recursive submodules:

```bash
mise install
git submodule update --init --recursive
```

Native provider builds require Apple Silicon and the Xcode/Metal toolchain
selected by `scripts/prepare-provider-release-toolchain.sh`. CI uses the reviewed
toolchain and separate native build outputs. Do not substitute an arbitrary
prebuilt metallib or infer GPU qualification from compilation alone.

## Build

```bash
make provider-build
make ui-install ui-build
make landing-install landing-build
```

`make provider-build` builds Swift products and stages the metallib through
`scripts/fetch-metallib.sh`. The kernel source is nested under
`libs/mlx-swift/Source/Cmlx/mlx`, matching the Cmlx target. Top-level `libs/mlx`
is a separate dependency pin. Native resources must match the compiled host
library; a warm cache cannot waive that requirement.

`landing/` has its own npm lockfile, configuration and API routes. It needs a
Next.js server runtime, not static file hosting. Follow its [README](../../landing/README.md)
for local development; keep production credentials out of builds and tests.

## Retained Console

`make ui-install` installs the console dependencies and `make ui-build` runs its
Next.js production build. For local preview, run `npm run dev` in `console-ui/`.
The existing `ui-lint`, `ui-test` and aggregate `ui` targets remain available,
along with the console CI lane and console-only pre-commit lint hook.

The console uses `console-ui/` as its hosting project root and requires a Next.js
server for same-origin `/api/*` routes, not static export. Existing
`console-ui/vercel.json` hosting configuration remains in place. Configure the
build-time public variables in the [configuration reference](../reference/configuration.md#console-ui)
and use a real Privy app for a hosted deployment; missing/placeholder Privy
configuration selects mock authentication. See [console architecture](../architecture/components/console-ui.md).
Retaining source or running a build does not authorize hosting or traffic changes.

## Verify

Follow [test](test.md) for provider, SDK and public fixture checks. Build success
does not prove runtime parity, real Apple attestation, model quality or a release.
Provider signing/publication follows [the release runbook](../operations/provider-release.md).

The public provider must build without backend source or a private checkout.
Private cross-implementation qualification remains a platform-owned gate, not
a hidden prerequisite fetched by the public build. See [ownership](navigation.md).

## Troubleshooting

Use source-matched submodules, the documented Xcode SDK and fresh resources when
diagnosing native failures. Preserve cache identity checks; do not bypass them
to reuse incompatible artifacts. Run `make clean` only when its provider/console/landing
artifact removal is intended. Never erase live provider state as build cleanup.

Do not repair an old backend trigger by reintroducing backend build targets here.
Backend build and deployment configuration belongs in the platform repository.

## Related

- [Provider and SDK tests](test.md)
- [Native ownership](navigation.md)
- [Serving-performance qualification](serving-performance-qualification.md)
- [Landing](../../landing/README.md)
