# Darkbloom desktop

Electron is the frontend. The Swift CLI is the backend and owns operations and
state. The interface uses the landing site's brand assets and generated tokens.

```bash
npm ci
npm run build
npm test
npm run dev
npm run package
```

## Run it locally

Prerequisites: Node 22+ (pinned in `mise.toml`), macOS on Apple Silicon for the
Electron window and runtime, and internet access for the preview's live
leaderboard data.

### UI preview (no runtime needed)

```bash
git fetch origin && git checkout feat/desktop-home-chip-animation
cd desktop-app
npm ci
node scripts/assets.mjs   # generates brand assets and tokens
npx vite                  # serves http://127.0.0.1:4318
```

Open `http://127.0.0.1:4318/?preview`. The preview uses a labeled development
fixture (a 64 GB M4 Max) and never starts the runtime or changes configuration.
Only the Leaderboard reads production, through the Vite proxy to the public
`/v1/stats` and `/v1/leaderboard`. Add these parameters to explore other states:

| Parameter                                   | Effect                                              |
| ------------------------------------------- | --------------------------------------------------- |
| `&chip=photoreal`                           | Photoreal chip art instead of the default blueprint |
| `&soc=M3%20Ultra&memory=512`                | Preview another chip and unified memory size (GB)   |
| `&onboarding=eligible\|ineligible\|unknown` | Onboarding hardware scan outcome                    |
| `&waitlist=fail`                            | Waitlist submission fails                           |
| `&account=unlinked`                         | Account not linked to this Mac                      |
| `&autopilot=shadow\|off\|unsupported`       | Model autopilot mode (default is on)                |

To see the same preview in the Electron window, keep Vite running and in a
second terminal run:

```bash
cd desktop-app
npm run build
DARKBLOOM_DEV_URL='http://127.0.0.1:4318/?preview' npm exec electron .
```

### Against a real runtime

From the repository root, build the CLI and start an isolated desktop API (it
does not install a service, start inference or contact production):

```bash
git submodule update --init --recursive
swift build --package-path provider-swift --product darkbloom
python3 scripts/test-desktop-api.py provider-swift/.build/debug/darkbloom --hold
```

Leave it running. It prints `DARKBLOOM_DESKTOP_DIR=…`. In another terminal:

```bash
cd desktop-app
npm run build
DARKBLOOM_CLI_PATH="$PWD/../provider-swift/.build/debug/darkbloom" \
DARKBLOOM_DESKTOP_ATTACH_ONLY=1 \
DARKBLOOM_DESKTOP_DIR='<printed path>' \
npm exec electron .
```

Run `provider-swift/.build/debug/darkbloom doctor --hardware` to check the
live chip-load sampling that drives the home screen. Outside `?preview`, data
that only production provides shows as "unavailable" or "—". That is expected.

More detail is in [development and qualification](../docs/developer/desktop-app.md).

## Notes

The native app normally connects to `~/.darkbloom/bin/darkbloom`; development
can override `DARKBLOOM_CLI_PATH`.

See [development and qualification](../docs/developer/desktop-app.md) and
[the native API](../docs/reference/desktop-control.md). Closing the window keeps
the menu bar available. Provider stop/restart always go through the CLI/backend.

## Design recovery points

The original Gajesh desktop, including Cooling and Earnings, is preserved at
`ba8e209b7` (local branch `codex/desktop-before-combined-design`). All feature
modules remain in this tree; the simplified sidebar changes discovery only.
Use `git show ba8e209b7:desktop-app/src/renderer/App.tsx` to inspect the original
navigation without resetting the working tree. The version immediately before
the My Macs redesign is also preserved on `codex/desktop-before-macs-design`
at `03fea81f3`.

Kaido's original reference is preserved in
[darkbloom-desktop-ui at 3025167](https://github.com/Layr-Labs/darkbloom-desktop-ui/tree/3025167).
The leaderboard adapts its pixel provider marks and public-domain Natural Earth
world grid. Neither its saved earnings snapshot nor mock Mac counts are used in
production. The reference repository is unchanged.
