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

## Homepage layout

After the map fills the viewport with blue, the provider films appear directly,
without a section headline or a separate headline scroll sequence. The gallery
holds briefly before releasing into the closing section.

The closing copy and laptop share a top edge on desktop. The paragraph uses
the copy column's width, and the headline, paragraph and button use equal gaps;
on phones the laptop follows the copy in normal flow.

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
new site's About page; the console is owned by the sibling
[platform repository](https://github.com/Layr-Labs/darkbloom-platform/tree/48a198c71a2d30feec5597bacf1101120f7f955d/console-ui).
`assets/cube-hero.png` remains available to public native inference fixtures.

Hosting operations require specific human approval. Landing keeps its own
server-side API routes; it does not build or deploy the centralized coordinator.
Existing upstream endpoints and environment variables are unchanged.

Use a budget-capped coordinator key for the public demo. The chat route's
in-memory rate limiter is per instance; distributed enforcement belongs in
the deployment's shared limiter or edge controls.

## Public discovery and representations

The public entry points are `/llms.txt`, `/auth.md`, `/openapi.json`,
`/sitemap.xml`, `/developers`, `/pricing` and `/contact`. The homepage and
explanatory pages support explicit Markdown twins (`/index.md`,
`/developers.md`, `/pricing.md`, `/contact.md`) and `Accept: text/markdown`.
Normal browser requests retain HTML. Read [API-CONTRACT.md](API-CONTRACT.md)
for the exact reviewed operation subset and its platform source revision.

Pricing reads the public coordinator source server-side, labels USD per million
tokens and retrieval time, and reports unavailable data without inventing rates.
Product facts and official links are shared across representations. See the
[architecture](../docs/architecture/components/landing.md) and the
[audit disposition](../docs/reports/2026-10-12-agent-readiness.md).

### Next.js Vary header patch

`npm run build` explicitly runs `scripts/preserve-next-vary.mjs` before Next.js
to preserve proxy `Vary` values in the pinned Next.js 16.2.6 page templates. This is a dependency-free, exact
replacement for [upstream issue 85999](https://github.com/vercel/next.js/issues/85999),
following [proposed fix 91039](https://github.com/vercel/next.js/pull/91039).
The script verifies the version and expected source, is idempotent, and fails
the build on unexpected code. Both CommonJS/ESM and Node/edge templates
receive the same merge behavior. Installation with `npm ci --ignore-scripts`
is supported because the patch is part of the explicit build command.
On a Next upgrade, remove it only after the production HTTP tests pass without
it, including HTML `Vary: Accept` plus framework tokens and alternating
HTML/Markdown requests.
