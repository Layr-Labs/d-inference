# Console UI

The console UI is Darkbloom's web frontend. It is a Next.js 16 / React 19 application that gives consumers a chat interface, model catalog, billing dashboard, API key management, and provider linking. All coordinator-facing requests are proxied through Next.js API routes so API keys and billing tokens stay server-side.

## Responsibilities

| Responsibility | Where it lives |
|---|---|
| Root layout, providers, analytics | `console-ui/src/app/layout.tsx` |
| Chat pages and API-route handlers | `console-ui/src/app/`, `console-ui/src/app/api/` |
| API client + sender→coordinator encryption | `console-ui/src/lib/api.ts`, `console-ui/src/lib/encryption.ts` |
| Global state (chats, selected model, "use my machine") | `console-ui/src/lib/store.ts` |
| Auth integration (Privy) | `console-ui/src/components/providers/PrivyClientProvider.tsx` |
| Reusable UI components (chat, trust badge, verification panel, etc.) | `console-ui/src/components/` |

## Key modules

### Application shell (`console-ui/src/app/`)

`layout.tsx` wraps every page in `ThemeProvider`, `PrivyClientProvider`, `VerificationModeProvider`, `AppShell`, and telemetry/analytics components. The chat and billing flows live under `src/app/`. API routes under `src/app/api/` act as a server-side proxy to the coordinator, avoiding CORS and keeping the user's API key out of client-side `fetch` headers where possible.

### API client (`console-ui/src/lib/api.ts`)

`api.ts` is the browser-side coordinator client. It exports typed helpers such as `fetchModels`, `fetchBalance`, `fetchUsage`, `createStripeCheckout`, and streaming chat helpers. Every request goes to a local `/api/*` route, which forwards to the upstream coordinator resolved from `NEXT_PUBLIC_COORDINATOR_URL` server-side.

The API key is read from `localStorage` under `darkbloom_api_key` and passed as `x-api-key`. Image content must be base64 `data:` URIs; remote `http(s)` or `file` URLs are rejected by the provider because media must ride inside the encrypted prompt.

### Sender→coordinator encryption (`console-ui/src/lib/encryption.ts`)

`encryption.ts` mirrors the coordinator's `sender_encryption.go`. When enabled in Settings, the UI:

1. Fetches the coordinator's long-lived X25519 key from `/api/encryption-key`.
2. Generates a fresh ephemeral X25519 keypair per request.
3. NaCl-Box-seals the request body with `Content-Type: application/eigeninference-sealed+json`.
4. Uses the ephemeral private key to unseal the coordinator's response.

The feature is opt-in and stored in `localStorage` under `darkbloom_encrypt_to_coordinator`.

### State management (`console-ui/src/lib/store.ts`)

`store.ts` is a Zustand store persisted to `localStorage`. It holds chat history, the active chat, the selected model, sidebar state, and the `useMyMachine` flag. When `useMyMachine` is true, chat requests are sent with `X-Darkbloom-Route: prefer`, telling the coordinator to prefer the user's own provider and fall back to the paid network if it cannot serve.

Base64 image data is stripped from persisted messages to avoid exceeding `localStorage` quota.

### Authentication (`console-ui/src/components/providers/PrivyClientProvider.tsx`)

Consumer login uses Privy. The provider uses the resulting session cookie for Privy-gated routes (billing, key management, provider linking). API-key authentication is used for inference endpoints.

## Privacy-relevant boundaries

- **API key storage**: The inference API key lives in `localStorage` and is sent as `x-api-key` through the Next.js API proxy. It is never embedded in page URLs or logged.
- **Prompt visibility**: Chat messages are rendered in the browser. They are sent to the coordinator over TLS and may be optionally sealed with sender→coordinator encryption. The UI never stores prompt content outside the browser's `localStorage`.
- **Image handling**: Images must be base64 `data:` URIs so they travel inside the encrypted request body. The UI rejects remote image URLs because the provider would receive them unencrypted.
- **Coordinator URL**: The upstream coordinator is resolved server-side from `NEXT_PUBLIC_COORDINATOR_URL`. Users can override it in Settings, but the proxy validates it before forwarding.
- **Telemetry**: The layout includes `TelemetryInitializer`, `GoogleAnalytics`, `Analytics`, and `DatadogRUM`. These are client-side observability tools and should not receive prompt text.

For the encryption model, see [`../security/encryption.md`](../security/encryption.md) and the coordinator-side description in [`coordinator.md`](coordinator.md).

## Outdated claims corrected

- The old `ARCHITECTURE.md` described the consumer SDK as the primary interface and did not cover the console UI's API-route proxy architecture. The console UI routes all coordinator calls through `/api/*` to avoid CORS and keep secrets server-side.
- The old doc's privacy statements about "the coordinator never sees plaintext prompts" are imprecise. The console UI can opt into sender→coordinator encryption, but plaintext TLS remains the default for compatibility.
