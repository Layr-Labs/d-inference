### Landing API rate-limit identity and body limits

- The homepage chat's per-visitor rate limit no longer trusts client-supplied
  `X-Forwarded-For` or `X-Real-IP`. On Vercel it uses `X-Forwarded-For`, which
  the platform overwrites; elsewhere `DARKBLOOM_TRUSTED_CLIENT_IP_HEADER` names
  the header the operator's proxy sets, and without it all visitors share one
  bucket. IPv6 visitors are limited per /64 and IPv4-mapped addresses as IPv4.
- The limiter's bucket map is capped at 10,000 entries and drops only expired
  buckets from its front, instead of scanning every bucket on each request once
  it held more than 10,000.
- `/api/chat` reads at most 16 KiB of request body and `/api/provider-stories`
  50,000 bytes, counted while the body is received, and answer HTTP 413 above
  that. A body without `Content-Length` (chunked or HTTP/2) can no longer skip
  the provider-story limit, and neither route parses an oversized body.
