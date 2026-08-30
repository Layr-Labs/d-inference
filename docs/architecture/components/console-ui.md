# Console UI

The console UI is Darkbloom's web frontend. It is a Next.js 16 / React 19 application that gives consumers a chat interface, model catalog, billing dashboard, API key management, and provider linking. All coordinator-facing requests are proxied through Next.js API routes so API keys and billing tokens stay server-side.

## Responsibilities

| Responsibility | Where it lives |
|---|---|
| Root layout, providers, analytics | `console-ui/src/app/layout.tsx` |
| Chat pages and API-route handlers | `console-ui/src/app/`, `console-ui/src/app/api/` |
| Browser private-v2 crypto + stream | `console-ui/src/lib/private-v2*.ts`, `console-ui/src/lib/chat/stream.ts` |
| Global state (chats, selected model, "use my machine") | `console-ui/src/lib/store.ts` |
| Auth integration (Privy) | `console-ui/src/components/providers/PrivyClientProvider.tsx` |
| Reusable UI components (chat, trust badge, verification panel, etc.) | `console-ui/src/components/` |

## Key modules

### Application shell (`console-ui/src/app/`)

`layout.tsx` wraps every page in `ThemeProvider`, `PrivyClientProvider`, `VerificationModeProvider`, `AppShell`, and telemetry/analytics components. The chat and billing flows live under `src/app/`. API routes under `src/app/api/` act as a server-side proxy to the coordinator, avoiding CORS and keeping the user's API key out of client-side `fetch` headers where possible.

### Private-v2 chat transport (`console-ui/src/lib/private-v2*.ts`)

Console Chat never sends prompt plaintext to its Next.js proxy or coordinator.
For each message it:

1. Requests a 60-second, single-use `/api/private/preflight` lease.
2. Verifies the selected provider's Apple MDA chain, SE freshness binding,
   SE-signed process transcript, and compile-time pinned release binary hash.
3. Generates a browser-ephemeral X25519 key and derives directional keys with
   HKDF-SHA256.
4. AES-256-GCM encrypts the transcript-bound request to the certified process.
5. Sends only the opaque envelope through `/api/private/requests` and decrypts
   ordered provider ciphertext chunks in the browser.

The proxies enforce authentication and byte bounds before buffering. They never
decrypt or log prompt/response content. Any preflight, proof, cryptographic, or
provider failure is surfaced; Chat does not retry a legacy endpoint.

`NEXT_PUBLIC_DARKBLOOM_PRIVATE_V2_RELEASE_HASHES` is a required comma-separated
compile-time allowlist of lowercase signed provider binary SHA-256 hashes. A
missing, invalid, or unpinned hash fails closed before X25519. It must be updated
when a newly signed provider release is admitted for private-v2 Chat.

### State management (`console-ui/src/lib/store.ts`)

`store.ts` is a Zustand store persisted to `localStorage`. It holds chat
history, active chat, selected model, sidebar state, and the `useMyMachine`
flag. Private v2 interprets `useMyMachine` strictly: route only to the linked
machine, with no paid-fleet fallback. Persisted state from the retired
prefer/fallback behavior is version-migrated off. Base64 image data is stripped
from persisted messages to avoid exceeding `localStorage` quota.

### Authentication (`console-ui/src/components/providers/PrivyClientProvider.tsx`)

Consumer login uses Privy. The provider uses the resulting session cookie for Privy-gated routes (billing, key management, provider linking). API-key authentication is used for inference endpoints.

## Privacy-relevant boundaries

- **API key storage**: The inference API key lives in `localStorage` and is sent as `x-api-key` through bounded same-origin proxies. It is never embedded in page URLs or logged.
- **Prompt visibility**: Private-v2 prompts and responses exist in plaintext only in the browser and certified provider process. The Next.js proxy and coordinator see ciphertext. Legacy API-console examples are explicitly coordinator-decryptable.
- **Provider proof disclosure**: Private preflight returns the selected provider's identity-bearing Apple MDA proof for independent local verification. It is kept in memory and is not rendered, persisted, logged, replay-captured, or sent to telemetry.
- **Image handling**: Images must be base64 `data:` URIs inside the encrypted body. Private-v2 enforces aggregate/plaintext bounds before preflight.
- **Coordinator URL**: The upstream coordinator is resolved server-side from `NEXT_PUBLIC_COORDINATOR_URL`; bounded proxy routes do not accept a client-supplied upstream.
- **Telemetry**: Datadog session replay is disabled and chat DOM/action text is privacy-masked. Observability must not receive prompts, responses, keys, or provider proof.

For the encryption model, see [`../security/encryption.md`](../security/encryption.md) and the coordinator-side description in [`coordinator.md`](coordinator.md).

## Legacy compatibility

The API console documents the existing OpenAI/Anthropic-compatible endpoints as
`legacy-coordinator-decryptable`. The retired optional sender→coordinator NaCl
transport remains in compatibility code for those clients, but Console Chat
uses only private v2.
