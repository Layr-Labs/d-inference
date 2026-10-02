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
