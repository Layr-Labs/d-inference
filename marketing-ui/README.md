# Darkbloom marketing site

The Next.js site imported from `eigen-homepages/apps/darkbloom`. It owns its
dependencies, TypeScript and ESLint configuration, API routes, fonts, and media.

## Development

Use the Node.js version pinned in the repository's `mise.toml`.

```bash
cd marketing-ui
npm ci
cp .env.example .env.local
npm run dev
```

Open `http://localhost:3008`. Run `npm run lint` and `npm run build` before
committing; `npm start` serves the production build on the same port.

The environment variables are listed in [.env.example](.env.example). The
server-only `DARKBLOOM_API_KEY` enables the homepage chat demo. Without it,
`/api/chat` returns an unavailable response. Network and model data use the
coordinator and console URLs; `/api/network` retains the imported site's
fixed fallback snapshot when live stats are unavailable. Provider-story
delivery requires `DARKBLOOM_STORY_WEBHOOK_URL` and, if applicable,
`DARKBLOOM_STORY_WEBHOOK_TOKEN`.

## Hosting

Use `marketing-ui` as the Vercel project root, with the Next.js framework
preset, `npm ci` for installation, and `npm run build` for the build. The
local `vercel.json` records those commands. This is a server-rendered app
with API routes and streaming chat, so it requires a Next.js server runtime.

For the existing marketing deployment, reconnect its Git repository to
`Layr-Labs/d-inference`, select this root, and retain its domains and
environment variables. Verify a preview before switching production. This
code import does not change project settings or DNS; the older static
`landing/` site is maintained separately.

Use a budget-capped coordinator key for the public demo. The chat route's
in-memory rate limiter is per instance; distributed enforcement belongs in
the deployment's shared limiter or edge controls.
