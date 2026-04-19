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

Analytics stays disabled unless `NEXT_PUBLIC_GA_MEASUREMENT_ID` is set **and** consent is granted. When a measurement ID is configured, the app shows a small in-app prompt so users can allow or decline analytics. Consent is persisted in `localStorage` under `darkbloom_ga_consent` (`granted` or `denied`), and a declined choice keeps analytics disabled until the user explicitly changes it later.

### Google Analytics setup

This frontend sends sanitized manual `page_view` events:

- the first pageview keeps only attribution parameters such as `utm_*`, `gclid`, `_gl`, and similar ad/campaign identifiers
- subsequent client-side navigations send clean path-based URLs without arbitrary query strings
- custom GA events also inherit sanitized `page_location` and `page_referrer` context

To avoid duplicate pageviews in GA4, disable **Enhanced measurement -> Page views -> Page changes based on browser history events** for the web data stream. The app already sets `send_page_view: false` in `gtag`, but GA4 history-based enhanced measurement is configured in the GA property and must also be turned off there when using manual SPA pageview tracking.

## Checks

```bash
npm run build
npx eslint src/
npm test
```
