# Build and validate the macOS desktop app

> Last updated: 2026-10-02

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
   Set `CSC_IDENTITY_AUTO_DISCOVERY=false` for an unsigned review build.

6. Choose the GUI update feed at build time. Packaging settings live in
   `desktop-app/electron-builder.ts` (`desktopBuildConfig`), not `package.json`;
   electron-builder discovers that file even without `--config`. The feed is
   opt-in:

   ```bash
   cd desktop-app
   DARKBLOOM_DESKTOP_UPDATE_URL=https://<desktop-update-host>/<path> npm run dist
   ```

   With the variable set (https only), electron-builder embeds a `generic` feed
   as `Darkbloom.app/Contents/Resources/app-update.yml` and writes the zip,
   blockmap and `latest-mac.yml` to `release/` for hosting at that URL. Without
   it the config sets `publish: null`. No `app-update.yml` is embedded, and
   electron-builder cannot infer a GitHub feed from `GH_TOKEN`/`GITHUB_TOKEN`.
   The app then never calls the updater, and Updates shows "Desktop app updates
   are not configured for this build." instead of failing every check.
   `--dir` builds (`make desktop-package`) never embed the file.

   The packaged app checks only when `app-update.yml` declares a `generic` https
   feed. The GUI must never use this repository's GitHub releases. Those are
   provider runtime releases with no `latest-mac.yml`.

## Verify

The primary sidebar contains Home, My Macs, Leaderboard, and Updates. The current
Mac's detail workspace uses Overview, Models, Cooling, Stats, and Settings
panels, with Studio and Earnings shortcuts;
Home retains the Earnings entry. These pages remain implemented, not deleted.
The machine rail changes into a horizontal selector on narrower windows. Other
machines are labeled **View only**, with status/earnings snapshots and no local
control panels. Selection stores the machine ID so new remote observations are
shown instead of retaining the originally clicked snapshot. Cancellable native
operations appear inline for the local Mac or fleet overview; Settings retains
Availability and Memory controls, and model metadata uses expandable details.
Leaderboard combines the reference's pixel world map and featured top three with
compact rows. It ranks actual 24-hour earnings from the native API and displays
annualized pace; expanding a provider shows the underlying earnings and tokens.
Missing location data never lights illustrative locations in production.


Home is a single-viewport contribution summary with session output tokens,
requests, network totals, and current model activity. Its preview animates
simulated requests gathering around model cores and fanning into token streams; production uses current native activity and never
invents stage events. Stats replaces Analysis and includes an inspectable traffic
curve, model traffic, and settled-token milestones. The current design preview
supplies clearly labeled sample 24-hour model traffic, outcome rate and generation
speed. Production shows observed interval deltas and leaves unavailable metrics
unknown. Future runtime/coordinator work must supply real per-model traffic bins,
request outcomes, generation speeds and request-stage events before those preview
metrics can become live. The particle canvas caps drawing at roughly 30 frames
per second, limits pixel density, and pauses off-screen, when hidden, when the
provider is inactive, or when motion is paused/reduced. Counter resets and
reversed timestamps are excluded.
 **View earnings** opens the desktop Earnings screen, which supports
7/30-day periods, earnings/output-token/request metrics, model/Mac breakdowns,
and exact **Copy CSV**. Failed reads retain a labeled prior observation only
within the same account session. New milestone crossings are celebrated once
while mounted; old achievements do not replay on navigation. Appearance is a
frontend preference with Light, Dark, and System options. Reduced motion and
the activity panel's pause control stop animation without stopping the provider.

`desktop-app/tests/insights.test.tsx` covers live/stale/crashed activity, exact
large integers, milestone boundaries, account-switch races, earnings navigation,
period/metric/breakdown controls, and appearance. `DesktopActivityTests` covers
the additive native state fields and opaque account revision. Coordinator tests
exercise token ownership/revocation and exact decimal-string responses; store
parity runs with `DATABASE_URL` set to a disposable local PostgreSQL database.

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

`.github/workflows/desktop.yml` runs the frontend tests and build, including
for changes to `scripts/install.sh`, which the app bundles. Manual workflow
dispatch also produces unsigned macOS review artifacts. It does not publish a
release or establish attestation qualification.

## Updates presentation

Updates shows installed/latest runtime versions, a compact release timeline and
an automatic provider-update switch. Provider configuration defaults to enabled;
the UI preserves an existing opt-out. Disabling asks for confirmation in both
Updates and Settings. Updates saves through the revision-checked native settings
action, and offers a provider restart to apply the setting to a running provider.
It never restarts automatically from a toggle.

A mandatory update is shown only when the installed version is below the
coordinator's published minimum. An available release alone is not mandatory.
Unknown policy remains unavailable; missing release notes are not invented.
The release-history resource requires the new coordinator endpoint to be deployed;
the existing latest-release display works independently. The browser development
preview contains explicitly illustrative release notes and version cutoffs.

## Release qualification

Before public distribution, verify all of the following against the final
signed frontend and signed provider artifact:

- Fresh install, existing CLI install, and repair use verified compatible payloads.
  The first runtime release must include the new `desktop` command; an older
  published CLI cannot provide this API.
- Deploy the reviewed coordinator projection before advertising fleet features.
  A missing endpoint appears as unavailable data, never sample account results.
- Choose and host the GUI update feed (`DARKBLOOM_DESKTOP_UPDATE_URL`, step 6),
  publish the signed zip and `latest-mac.yml` there, and verify GUI update
  download, restart and rollback separately from native update.
- Verify notarization, Gatekeeper, the provisioned provider bundle, App Attest,
  source-matched metallib/resources, and the existing fan helper on real hardware.
- Exercise a real eligible model through download, start, inference, local/network
  mode changes, graceful stop, restart, sleep/wake and reboot. Preserve provider
  identity/configuration and verify both app and CLI agree afterward.
- Exercise API interruption during a long operation. The operation journal marks
  an interrupted operation for reconciliation; automatic exactly-once replay is
  not implemented. Do not retry until native state is known.
- Log out and back in after the first packaged launch: the menu bar item appears
  and no window opens (`wasOpenedAtLogin`). Reopening the app shows the window.
- Confirm desktop redistribution rights for the supplied fonts.

See [provider releases](../operations/provider-release.md) and
[coordinator deployment](../operations/coordinator-deploy.md) for the independently
authorized release/deploy procedures.

## Launch at login

The first packaged launch registers the app as a macOS login item (the default
`mainAppService`) once; later changes in System Settings are kept. Login-item
`args` are Windows-only in Electron, so a login launch is detected through
`app.getLoginItemSettings().wasOpenedAtLogin` (`launchedHidden` in
`desktop-app/src/main/loginLaunch.ts`) and starts without a window. The
menu bar item stays available. Passing `--hidden` also starts hidden.

## Main-process layout

`desktop-app/src/main/index.ts` only wires the modules below together;
`desktop-app/scripts/build.mjs` bundles them into `dist/main.cjs`.

| Module | Responsibility |
|--------|----------------|
| `desktop-app/src/main/security.ts` | IPC sender/frame/origin checks, navigation and link allowlists, renderer path guard, CSP, clipboard bounds (electron-free, unit tested) |
| `desktop-app/src/main/protocol.ts` | privileged `darkbloom://` scheme and renderer file serving |
| `desktop-app/src/main/window.ts` | the sandboxed main window; close hides |
| `desktop-app/src/main/ipc.ts` | renderer-callable channels, each gated by `isTrustedSender` |
| `desktop-app/src/main/tray.ts`, `desktop-app/src/main/trayMenu.ts` | menu bar item; the native menu rebuilds only when its state model changes |
| `desktop-app/src/main/appMenu.ts`, `desktop-app/src/main/notifications.ts`, `desktop-app/src/main/lifecycle.ts` | application menu, failed-operation notification, quit state |
| `desktop-app/src/main/loginLaunch.ts` | login-item registration and hidden login launch |
| `desktop-app/src/main/updates.ts`, `desktop-app/src/main/updateFeed.ts` | GUI self-update and the build-time feed contract |
| `desktop-app/src/main/backend.ts` | runtime discovery, signature checks and the native API client |

`Backend.verifyRuntime` checks the runtime's code signature in packaged builds before
running `desktop ensure` or `update`.
