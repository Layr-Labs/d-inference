### Landing API request handling (security)

- The landing site's API routes apply stricter request limits: request bodies
  are read only up to a fixed size (HTTP 413 above it), and the homepage chat's
  per-visitor rate limiter keeps bounded state. Ordinary visitors are
  unaffected.
- Behind a proxy other than Vercel's, set `DARKBLOOM_TRUSTED_CLIENT_IP_HEADER`
  to the header that proxy sets with the visitor's address; without it, the
  chat's rate limit treats all visitors as one.
