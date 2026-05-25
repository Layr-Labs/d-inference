import type { NextConfig } from "next";

// Content-Security-Policy directives.
// - 'unsafe-inline' for style-src: required by Next.js for injected styles.
// - 'unsafe-inline' + 'unsafe-eval' for script-src: required by Privy SDK
//   and Next.js dev mode. Tighten to nonce-based CSP when feasible.
// - connect-src: coordinator API, Privy auth, Google Analytics, Stripe.
// - frame-src: Privy auth iframes, Stripe Checkout iframes.
const cspDirectives = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://www.googletagmanager.com https://js.stripe.com",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https:",
  "font-src 'self' data:",
  "connect-src 'self' https://api.darkbloom.dev https://*.privy.io wss://*.privy.io https://www.google-analytics.com https://api.stripe.com",
  "frame-src https://auth.privy.io https://js.stripe.com",
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
