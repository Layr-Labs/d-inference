# Darkbloom desktop review Storybook

Before/After stories and walkthroughs for the desktop UI audit (Layr-Labs/d-inference
#1452–#1508). Each comparison renders the real desktop components twice with the same fixtures:

- **After** is the live app in this repository (`desktop-app/src`, `desktop-app/tests` fixtures).
  Stories import it as `src/after/desktop-app/…`; `.storybook/main.ts` maps that prefix to the
  desktop app, so no copy is kept and the stories always show the current code.
- **Before** is `src/before/`, a frozen snapshot of `bfa75a2c` (the base the audit PRs targeted).

`stories/DistributionFlow.mdx` (*Install flow*) describes the end-to-end install flow (DMG →
Install the Darkbloom CLI → check → link → start). *App shell › Pages* renders the real `App` (with its
sidebar) at each page; stories open a page through the mocked bridge's `onNavigate`
(`bridges.after.navigate(route)`, or `<AtRoute>` in `stories/support/Shell.tsx`).

`brand.css` and `public/` are the app's generated assets (`desktop-app/scripts/assets.mjs`).
The native bridge is mocked per version (`stories/support/`); no runtime, account or production
endpoint is contacted. Its `system()` reports macOS 27.0 unless a story passes `macosVersion`
(`resetBridges({ macosVersion: '26.5' })`, `shellFixtures({ macosVersion })`); `openSoftwareUpdate()`
is only logged.

```bash
cd desktop-app
node scripts/assets.mjs      # generates brand.css and the app icons the stories use
cd storybook
npm ci
npm run storybook            # http://127.0.0.1:6106
npm run build-storybook      # static site in storybook-static/
```

CSS-only fixes from the second pass are shown as headless-Chrome captures in `public/evidence/`
(global styles can't differ between two panes of one page); they are static images.
