# Darkbloom marketing site

The Next.js site imported from `eigen-homepages/apps/darkbloom`. It owns its
dependencies, TypeScript and ESLint configuration, API routes, fonts, and media.

## Development

Use the Node.js version pinned in the repository's `mise.toml`.

```bash
cd landing
npm ci
cp .env.example .env.local
npm run dev
```

Open `http://localhost:3008`. Run `npm run lint` and `npm run build` before
committing, then `npm test` for HTTP route checks; `npm start` serves the
production build on the same port. `make landing` runs all checks from the
repository root.

The environment variables are listed in [.env.example](.env.example). The
server-only `DARKBLOOM_API_KEY` enables the homepage chat demo. Without it,
`/api/chat` returns an unavailable response. Network and model data use the
coordinator and console URLs; `/api/network` retains the imported site's
fixed fallback snapshot when live stats are unavailable. Provider-story
delivery requires `DARKBLOOM_STORY_WEBHOOK_URL` and, if applicable,
`DARKBLOOM_STORY_WEBHOOK_TOKEN`.

## Hosting

Use `landing` as the Vercel project root, with the Next.js framework
preset, `npm ci` for installation, and `npm run build` for the build. The
local `vercel.json` records those commands and the `.next` output directory.
This is a server-rendered app with API routes and streaming chat, so it
requires a Next.js server runtime.

For the existing marketing deployment, reconnect its Git repository to
`Layr-Labs/d-inference`, select `landing` as the root, and retain its domains
and environment variables. The existing landing project also uses this root;
its build must now use the Next.js settings above instead of serving static
HTML. Verify a preview before switching production. This PR does not change
project settings or DNS.

The old `/index.html`, `/terms.html` and `/privacy.html` URLs permanently
redirect to `/`, `/terms` and `/privacy`. The published terms and privacy
text is preserved. The old homepage earnings calculator is replaced by the
new site's About page; the console's calculator remains available in
`console-ui/`. `assets/cube-hero.png` is retained solely for existing
inference test fixtures.

Use a budget-capped coordinator key for the public demo. The chat route's
in-memory rate limiter is per instance; distributed enforcement belongs in
the deployment's shared limiter or edge controls.
