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
- `NEXT_PUBLIC_GA_MEASUREMENT_ID` - optional Google Analytics 4 measurement ID

If `NEXT_PUBLIC_GA_MEASUREMENT_ID` is set, the app loads the Google tag and sends pageview events for App Router navigations. If it is unset, analytics stays completely disabled.

## Checks

```bash
npm run build
npx eslint src/
npm test
```
