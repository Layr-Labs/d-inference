// Package mediafetch resolves remote http(s) media URLs (image_url / video_url)
// embedded in OpenAI-compatible inference request bodies into inline base64
// `data:` URIs, on the coordinator, before the body is end-to-end-encrypted to a
// provider.
//
// Why coordinator-side: the Swift provider deliberately rejects any non-`data:`
// URI as an SSRF guard (providers run on consumer-owned Macs whose LANs must not
// be probed). The coordinator is the more-trusted component (TEE/cloud) and is a
// single chokepoint: it fetches each URL exactly once per request — not once per
// speculative/failover dispatch — applies strict SSRF defenses, re-encodes the
// bytes as a `data:` URI, and hands the provider the same inline shape it already
// accepts. The provider's guard is therefore unchanged (defense in depth).
//
// Sender-sealed (zero-knowledge) requests are never fetched here: the coordinator
// must not unseal-to-fetch, so a sealed request carrying a remote URL is rejected
// by the caller (see HasRemoteMedia) and must use an inline `data:` URI instead.
package mediafetch

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Environment variable names (EIGENINFERENCE_ prefix, per coordinator/env).
const (
	envEnabled        = env.EnvPrefix + "_MEDIA_FETCH_ENABLED"
	envMaxFileBytes   = env.EnvPrefix + "_MEDIA_FETCH_MAX_FILE_BYTES"
	envMaxTotalBytes  = env.EnvPrefix + "_MEDIA_FETCH_MAX_TOTAL_BYTES"
	envMaxParts       = env.EnvPrefix + "_MEDIA_FETCH_MAX_PARTS"
	envTimeoutMS      = env.EnvPrefix + "_MEDIA_FETCH_TIMEOUT_MS"
	envTotalDeadline  = env.EnvPrefix + "_MEDIA_FETCH_TOTAL_DEADLINE_MS"
	envConcurrency    = env.EnvPrefix + "_MEDIA_FETCH_CONCURRENCY"
	envBlocklist      = env.EnvPrefix + "_MEDIA_FETCH_BLOCKLIST_DOMAINS"
	envAllowPrivateIP = env.EnvPrefix + "_MEDIA_FETCH_ALLOW_PRIVATE_IPS"
)

// Defaults. The byte caps are reconciled against the COORDINATOR's own 16 MiB
// forwarded-body cap (api.maxInferenceBodyBytes — the body the coordinator
// re-marshals and seals), which is the binding constraint, not just the provider's
// 32 MiB WebSocket frame. Raw media of M bytes inflates to ~1.37*M as a base64
// data: URI, so the aggregate raw cap must leave headroom under 16 MiB for the
// inlined media PLUS the rest of the request (prompt text, JSON structure, the
// coordinator-injected max_tokens). A 10 MiB aggregate raw cap inlines to ~13.3 MiB,
// leaving ~2.7 MiB for everything else — so a valid request is never fetched only to
// be rejected by the final 16 MiB body check.
const (
	DefaultMaxFileBytes  int64 = 8 << 20  // 8 MiB per fetched file
	DefaultMaxTotalBytes int64 = 10 << 20 // 10 MiB aggregate raw media/request (~13.3 MiB inlined)
	DefaultMaxParts            = 10       // max remote media parts per request
	DefaultTimeout             = 15 * time.Second
	DefaultTotalDeadline       = 25 * time.Second
	DefaultConcurrency         = 4
)

// Config controls remote media resolution. The zero value is not usable; build
// one with ConfigFromEnv or DefaultConfig.
type Config struct {
	// Enabled gates the whole feature. When false, any request carrying a
	// remote http(s) media URL is rejected (inline data: URIs still work).
	Enabled bool
	// MaxFileBytes caps a single fetched media item (raw bytes, pre-base64).
	MaxFileBytes int64
	// MaxTotalBytes caps the sum of all fetched media in one request.
	MaxTotalBytes int64
	// MaxParts caps the number of remote media URLs fetched per request.
	MaxParts int
	// FetchTimeout bounds a single fetch (connect + read), independent of the
	// request's TTFT deadline so a slow origin fails at the coordinator rather
	// than starving the provider.
	FetchTimeout time.Duration
	// TotalDeadline bounds the whole resolution step across all parts.
	TotalDeadline time.Duration
	// Concurrency is the fetch worker-pool size.
	Concurrency int
	// BlocklistDomains is an optional set of lowercased hostnames to reject
	// (applied to the initial host and every redirect host). Empty = no domain
	// blocklist; IP-level SSRF defenses always apply regardless.
	BlocklistDomains map[string]bool
	// AllowPrivateIPs disables the private/loopback/link-local/metadata IP deny
	// policy. Default false. Set true only in dev/tests (httptest binds 127.0.0.1).
	AllowPrivateIPs bool
}

// DefaultConfig returns the production defaults (feature enabled).
func DefaultConfig() Config {
	return Config{
		Enabled:          true,
		MaxFileBytes:     DefaultMaxFileBytes,
		MaxTotalBytes:    DefaultMaxTotalBytes,
		MaxParts:         DefaultMaxParts,
		FetchTimeout:     DefaultTimeout,
		TotalDeadline:    DefaultTotalDeadline,
		Concurrency:      DefaultConcurrency,
		BlocklistDomains: map[string]bool{},
		AllowPrivateIPs:  false,
	}
}

// ConfigFromEnv builds a Config from EIGENINFERENCE_MEDIA_FETCH_* env vars,
// falling back to DefaultConfig for anything unset or unparseable.
func ConfigFromEnv() Config {
	c := DefaultConfig()
	c.Enabled = envBool(envEnabled, c.Enabled)
	c.MaxFileBytes = int64(env.EnvInt(envMaxFileBytes, int(c.MaxFileBytes)))
	c.MaxTotalBytes = int64(env.EnvInt(envMaxTotalBytes, int(c.MaxTotalBytes)))
	c.MaxParts = env.EnvInt(envMaxParts, c.MaxParts)
	c.FetchTimeout = time.Duration(env.EnvInt(envTimeoutMS, int(c.FetchTimeout/time.Millisecond))) * time.Millisecond
	c.TotalDeadline = time.Duration(env.EnvInt(envTotalDeadline, int(c.TotalDeadline/time.Millisecond))) * time.Millisecond
	c.Concurrency = env.EnvInt(envConcurrency, c.Concurrency)
	c.BlocklistDomains = parseBlocklist(env.EnvOr(envBlocklist, ""))
	c.AllowPrivateIPs = envBool(envAllowPrivateIP, c.AllowPrivateIPs)
	return c.sanitized()
}

// sanitized clamps nonsensical values to safe defaults so a misconfigured env
// can't disable a cap (e.g. MaxParts<=0 would otherwise admit unbounded fetches).
func (c Config) sanitized() Config {
	if c.MaxFileBytes <= 0 {
		c.MaxFileBytes = DefaultMaxFileBytes
	}
	if c.MaxTotalBytes <= 0 {
		c.MaxTotalBytes = DefaultMaxTotalBytes
	}
	if c.MaxFileBytes > c.MaxTotalBytes {
		// The aggregate per-request cap is authoritative: a larger per-file cap
		// must never admit more than the operator's total budget. Clamp the file
		// cap down to the total rather than weakening (raising) the total.
		c.MaxFileBytes = c.MaxTotalBytes
	}
	if c.MaxParts <= 0 {
		c.MaxParts = DefaultMaxParts
	}
	if c.FetchTimeout <= 0 {
		c.FetchTimeout = DefaultTimeout
	}
	if c.TotalDeadline <= 0 {
		c.TotalDeadline = DefaultTotalDeadline
	}
	if c.Concurrency <= 0 {
		c.Concurrency = DefaultConcurrency
	}
	if c.BlocklistDomains == nil {
		c.BlocklistDomains = map[string]bool{}
	}
	return c
}

// parseBlocklist turns a comma-separated domain list into a lowercased set.
func parseBlocklist(csv string) map[string]bool {
	out := map[string]bool{}
	for _, raw := range strings.Split(csv, ",") {
		// Strip a trailing FQDN dot so "evil.com." and "evil.com" canonicalize the
		// same way hostAllowed canonicalizes request hosts (no trailing-dot bypass).
		h := strings.TrimRight(strings.ToLower(strings.TrimSpace(raw)), ".")
		if h != "" {
			out[h] = true
		}
	}
	return out
}

// envBool parses a boolean env var (true/1/yes/on), falling back when unset.
func envBool(key string, fallback bool) bool {
	switch strings.ToLower(strings.TrimSpace(env.EnvOr(key, ""))) {
	case "":
		return fallback
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}
