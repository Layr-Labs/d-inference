## Console UI

Frontend for Darkbloom's consumer and provider flows, built with Next.js App Router.

## Getting Started

```bash
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Environment variables

Client-side variables used by the app:

- `NEXT_PUBLIC_COORDINATOR_URL` - coordinator API base URL
- `NEXT_PUBLIC_PRIVY_APP_ID` - Privy application ID
- `NEXT_PUBLIC_SOLANA_RPC_URL` - Solana RPC endpoint
- `NEXT_PUBLIC_GA_MEASUREMENT_ID` - optional public Google Analytics 4 measurement ID

If `NEXT_PUBLIC_GA_MEASUREMENT_ID` is set, the app loads the Google tag and sends manual pageview events for App Router navigations. If it is unset, analytics stays completely disabled.

### Google Analytics setup

This frontend sends sanitized manual `page_view` events:

- the first pageview keeps only attribution parameters such as `utm_*`, `gclid`, `_gl`, and similar ad/campaign identifiers
- subsequent client-side navigations send clean path-based URLs without arbitrary query strings

To avoid duplicate pageviews in GA4, disable **Enhanced measurement -> Page views -> Page changes based on browser history events** for the web data stream. The app already sets `send_page_view: false` in `gtag`, but GA4 history-based enhanced measurement is configured in the GA property and must also be turned off there when using manual SPA pageview tracking.

## Checks

```bash
npm run build
npx eslint src/
npm test
```
