import type { NextConfig } from "next";

// Content-Security-Policy directives.
// - 'unsafe-inline' for style-src: required by Next.js for injected styles.
// - 'unsafe-inline' + 'unsafe-eval' for script-src: required by Privy SDK
//   and Next.js dev mode. Tighten to nonce-based CSP when feasible.
// - script-src: GA/GTM, Stripe.js, Cloudflare Turnstile (Privy captcha).
// - connect-src: coordinator API, Privy auth + RPC, WalletConnect/WalletLink
//   relays & explorer, Google Analytics, Stripe.
// - frame-src / child-src: Privy auth iframe, WalletConnect verify iframes,
//   Cloudflare Turnstile, Stripe Checkout.
// - worker-src: app workers (Privy/wagmi may spawn blob: workers).
const cspDirectives = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://www.googletagmanager.com https://js.stripe.com https://challenges.cloudflare.com",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https:",
  "font-src 'self' data:",
  "connect-src 'self' https://api.darkbloom.dev https://*.privy.io wss://*.privy.io https://*.rpc.privy.systems https://www.google-analytics.com https://api.stripe.com https://*.walletconnect.com wss://*.walletconnect.com https://*.walletconnect.org wss://*.walletconnect.org wss://www.walletlink.org",
  "frame-src 'self' https://auth.privy.io https://js.stripe.com https://challenges.cloudflare.com https://verify.walletconnect.com https://verify.walletconnect.org",
  "child-src 'self' https://auth.privy.io https://verify.walletconnect.com https://verify.walletconnect.org",
  "worker-src 'self' blob:",
  "frame-ancestors 'none'",
  "base-uri 'self'",
  "form-action 'self'",
].join("; ");

const securityHeaders = [
  { key: "Content-Security-Policy", value: cspDirectives },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Strict-Transport-Security", value: "max-age=63072000; includeSubDomains; preload" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
];

const nextConfig: NextConfig = {
  allowedDevOrigins: ["127.0.0.1"],
  // Tree-shake barrel imports for icon-heavy packages so only the icons we use
  // ship (perf F14). lucide-react is imported at ~47 sites across the app.
  experimental: {
    optimizePackageImports: ["lucide-react"],
  },
  typescript: {
    // @noble/curves >=1.9 ships raw .ts files with .ts import extensions,
    // which fails Next.js type-checking even with skipLibCheck: true.
    // This is a known upstream issue in viem's dependency tree.
    ignoreBuildErrors: true,
  },
  async headers() {
    return [
      {
        source: "/(.*)",
        headers: securityHeaders,
      },
    ];
  },
};

export default nextConfig;
