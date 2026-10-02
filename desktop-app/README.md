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

For a UI-only preview, start Vite on port 4318 and visit `/?preview`.
Preview data is explicitly development-only. The native app normally connects
to `~/.darkbloom/bin/darkbloom`; development can override `DARKBLOOM_CLI_PATH`.

See [development and qualification](../docs/developer/desktop-app.md) and
[the native API](../docs/reference/desktop-control.md). Closing the window keeps
the menu bar available. Provider stop/restart always go through the CLI/backend.

## Design recovery points

The original Gajesh desktop, including Cooling and Earnings, is preserved at
`ba8e209b7` (local branch `codex/desktop-before-combined-design`). All feature
modules remain in this tree; the simplified sidebar changes discovery only.
Use `git show ba8e209b7:desktop-app/src/renderer/App.tsx` to inspect the original
navigation without resetting the working tree.

Kaido's original reference is preserved in
[darkbloom-desktop-ui at 3025167](https://github.com/Layr-Labs/darkbloom-desktop-ui/tree/3025167).
The leaderboard adapts its pixel provider marks and public-domain Natural Earth
world grid. Neither its saved earnings snapshot nor mock Mac counts are used in
production. The reference repository is unchanged.
