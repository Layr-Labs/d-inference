# Build and validate the macOS desktop app

> Last updated: 2026-10-01

Build the Electron frontend and its Swift CLI/backend API in this repository.
This guide covers development and review artifacts; production distribution also
requires the release qualifications below.

## Prerequisites

- Apple Silicon macOS, the repository toolchain, and initialized Swift submodules.
- Node.js 22.12 or later and npm for `desktop-app/`.
- The usual provider build prerequisites in [build](build.md).

## Steps

1. Install and build the frontend:

   ```bash
   make desktop-install
   make desktop-build
   ```

   Build scripts copy the landing page's fonts/logo and generate shared color
   tokens and the icon. Generated copies are ignored by Git; edit the sources in
   `landing/`. PP Telegraf remains governed by its supplied license.

2. Preview UI development without touching a provider:

   ```bash
   cd desktop-app
   npm exec vite -- --host 127.0.0.1 --port 4318
   ```

   Open `http://127.0.0.1:4318/?preview`. The explicit development fixture is
   labeled and compiled out of the production renderer. To inspect the same
   fixture in an Electron window, build first and run:

   ```bash
   DARKBLOOM_DEV_URL='http://127.0.0.1:4318/?preview' npm exec electron .
   ```

   This preview does not start the native API, mutate configuration, or send
   requests to production.

3. Build the CLI/backend and test its real HTTP boundary:

   ```bash
   swift build --package-path provider-swift --product darkbloom
   make desktop-api-test
   ```

   The integration test starts a temporary API process and local fake catalog.
   Its `--hold` option keeps the isolated API available for an Electron integration
   check. Set `DARKBLOOM_DESKTOP_ATTACH_ONLY=1`, the printed `DARKBLOOM_DESKTOP_DIR`,
   and `DARKBLOOM_CLI_PATH` in development to attach without installing a service.
   It isolates config, model cache, credentials, discovery, endpoint, and daemon
   state; it does not start inference or contact production.

4. For deliberate native integration, use `npm run dev` in `desktop-app/`.
   Development may set `DARKBLOOM_CLI_PATH` to a built CLI. The normal app connects
   to the canonical installed runtime and manages its API LaunchAgent. This is
   an operator action, not an isolated test; use a dedicated test user/profile
   for lifecycle qualification.

5. Build a review application:

   ```bash
   make desktop-package
   ```

   The result is `desktop-app/release/mac-arm64/Darkbloom.app` with bundle ID
   `io.darkbloom.desktop`. The provider retains `io.darkbloom.provider` under
   its canonical user installation. The packaging command never publishes. Launching the packaged executable with
   `--ui-smoke-test` disables backend connection, login-item changes, and update
   checks for an isolated packaged-renderer check.
   If a valid Developer ID is available, electron-builder signs the GUI;
   notarization requires its configured credentials. Verify the actual result.

## Verify

```bash
make desktop-test
make desktop-api-test
make docs-impact-check BASE=origin/master
make docs-check
```

`DesktopControlTests` covers the native auth and validation boundary.
`TestDesktopAccountTokenIsolationAndRevocation` covers the coordinator projection
using a real in-process HTTP server and store. The ordinary provider/coordinator
component suites remain required for changes to their shared code.

`.github/workflows/desktop.yml` runs the frontend tests and build. Manual workflow
dispatch also produces unsigned macOS review artifacts. It does not publish a
release or establish attestation qualification.

## Release qualification

Before public distribution, verify all of the following against the final
signed frontend and signed provider artifact:

- Fresh install, existing CLI install, and repair use verified compatible payloads.
  The first runtime release must include the new `desktop` command; an older
  published CLI cannot provide this API.
- Deploy the reviewed coordinator projection before advertising fleet features.
  A missing endpoint appears as unavailable data, never sample account results.
- Publish the GUI zip and `latest-mac.yml` to the configured GitHub release feed;
  verify GUI update download, restart and rollback separately from native update.
- Verify notarization, Gatekeeper, the provisioned provider bundle, App Attest,
  source-matched metallib/resources, and the existing fan helper on real hardware.
- Exercise a real eligible model through download, start, inference, local/network
  mode changes, graceful stop, restart, sleep/wake and reboot. Preserve provider
  identity/configuration and verify both app and CLI agree afterward.
- Exercise API interruption during a long operation. The operation journal marks
  an interrupted operation for reconciliation; automatic exactly-once replay is
  not implemented. Do not retry until native state is known.
- Confirm desktop redistribution rights for the supplied fonts.

See [provider releases](../operations/provider-release.md) and
[coordinator deployment](../operations/coordinator-deploy.md) for the independently
authorized release/deploy procedures.
