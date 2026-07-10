// Package mediafetch resolves remote http(s) media URLs (image_url / video_url)
// embedded in OpenAI-compatible inference request bodies into inline base64
// `data:` URIs, on the coordinator, before the body is end-to-end-encrypted to a
// provider.
//
// Why coordinator-side: the Swift provider deliberately rejects any non-`data:`
// URI as an SSRF guard (providers run on consumer-owned Macs whose LANs must not
// be probed — see MediaIngest.swift). The coordinator is the more-trusted
// component (TEE/CVM) and a single chokepoint: it fetches each URL exactly once
// per request — not once per speculative/failover dispatch — applies strict SSRF
// defenses, re-encodes the bytes as a `data:` URI, and hands the provider the
// same inline shape it already accepts. The provider's guard is therefore
// unchanged (defense in depth).
//
// Safety posture ("is it malware?"): fetched bytes are never executed or parsed
// beyond header sniffing here. Defenses are structural and layered:
//
//   - SSRF: scheme allowlist, no embedded credentials, optional domain
//     blocklist, and a connect-time IP deny policy (loopback/private/link-local/
//     metadata/CGNAT/IPv6-transition/reserved) enforced in the dialer Control hook,
//     runs on the post-DNS-resolution address of EVERY dial including each
//     redirect hop — DNS-rebinding-proof (ssrf.go).
//   - Content: the data: URI is built from the SNIFFED type (magic bytes), never
//     the spoofable Content-Type header; only formats the provider's decoders
//     (CoreImage / AVFoundation) actually support are inlined; an image_url part
//     must sniff as an image and a video_url part as a video; HTML/SVG/scripts/
//     executables/polyglots fail the allowlist (sniff.go).
//   - Bombs: per-file and shared per-request byte caps enforced while reading
//     (Content-Length is only a pre-check), no transparent decompression, and a
//     header-only megapixel cap for every accepted image format mirroring the
//     provider's own pre-raster pixel gate (fetch.go, budget.go, sniff.go). The
//     provider's decode-time caps (pixels, bytes, video duration/frames) remain
//     the second, authoritative layer.
//   - Resource use: per-request part count/concurrency caps, a process-wide
//     fetch semaphore, and per-fetch + whole-step deadlines.
//
// Sender-sealed requests are never fetched: the sender opted into sealing the
// payload to the coordinator, and fetching would generate origin-observable
// egress correlated with that request. The API layer rejects sealed requests
// carrying remote URLs (see api.gateRemoteMediaPreDispatch) and tells the sender
// to inline a data: URI instead.
package mediafetch

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Environment variable names (EIGENINFERENCE_ prefix, per coordinator/env).
const (
	envEnabled         = env.EnvPrefix + "_MEDIA_FETCH_ENABLED"
	envMaxFileBytes    = env.EnvPrefix + "_MEDIA_FETCH_MAX_FILE_BYTES"
	envMaxTotalBytes   = env.EnvPrefix + "_MEDIA_FETCH_MAX_TOTAL_BYTES"
	envMaxParts        = env.EnvPrefix + "_MEDIA_FETCH_MAX_PARTS"
	envTimeoutMS       = env.EnvPrefix + "_MEDIA_FETCH_TIMEOUT_MS"
	envTotalDeadline   = env.EnvPrefix + "_MEDIA_FETCH_TOTAL_DEADLINE_MS"
	envConcurrency     = env.EnvPrefix + "_MEDIA_FETCH_CONCURRENCY"
	envGlobalConc      = env.EnvPrefix + "_MEDIA_FETCH_GLOBAL_CONCURRENCY"
	envMaxMegapixels   = env.EnvPrefix + "_MEDIA_FETCH_MAX_IMAGE_MEGAPIXELS"
	envBlocklist       = env.EnvPrefix + "_MEDIA_FETCH_BLOCKLIST_DOMAINS"
	envAllowPrivateIP  = env.EnvPrefix + "_MEDIA_FETCH_ALLOW_PRIVATE_IPS"
	envAllowOtherPorts = env.EnvPrefix + "_MEDIA_FETCH_ALLOW_NONSTANDARD_PORTS"
)

// Defaults. The byte caps are reconciled against the COORDINATOR's own 16 MiB
// forwarded-body cap (api.maxInferenceBodyBytes — the body the coordinator
// re-marshals and seals), which is the binding constraint, not just the
// provider's 32 MiB WebSocket frame. Raw media of M bytes inflates to ~1.37*M as
// a base64 data: URI, so the aggregate raw cap must leave headroom under 16 MiB
// for the inlined media PLUS the rest of the request (prompt text, JSON
// structure, the coordinator-injected max_tokens). A 10 MiB aggregate raw cap
// inlines to ~13.3 MiB, leaving ~2.7 MiB for everything else — so a valid
// request is never fetched only to be rejected by the final 16 MiB body check.
//
// DefaultMaxImageMegapixels mirrors the provider's DARKBLOOM_MAX_IMAGE_MEGAPIXELS
// default (100 MP, header-read before rasterization) so the coordinator rejects
// pixel bombs before dispatch instead of shipping them across the fleet.
const (
	DefaultMaxFileBytes       int64 = 8 << 20  // 8 MiB per fetched file
	DefaultMaxTotalBytes      int64 = 10 << 20 // 10 MiB aggregate raw media/request (~13.3 MiB inlined)
	DefaultMaxParts                 = 8        // max remote media parts per request (matches the provider's videos/request cap)
	DefaultTimeout                  = 15 * time.Second
	DefaultTotalDeadline            = 25 * time.Second
	DefaultConcurrency              = 4   // per-request fetch workers
	DefaultGlobalConcurrency        = 32  // process-wide in-flight fetch cap
	DefaultMaxImageMegapixels       = 100 // header-decoded image pixel cap (all accepted image formats)
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
	// Concurrency is the per-request fetch worker-pool size.
	Concurrency int
	// GlobalConcurrency caps in-flight fetches across ALL requests (one shared
	// semaphore per Resolver) so a burst of media-heavy requests can't open an
	// unbounded number of outbound sockets from the coordinator.
	GlobalConcurrency int
	// MaxImageMegapixels caps decoded image dimensions (width×height), checked
	// from the image HEADER only (never a full decode) for every accepted format
	// (JPEG/PNG/GIF/WebP/BMP). 0 disables the coordinator-side check; the
	// provider's own pre-raster pixel cap still applies.
	MaxImageMegapixels int
	// BlocklistDomains is an optional set of lowercased hostnames to reject
	// (applied to the initial host and every redirect host). Empty = no domain
	// blocklist; IP-level SSRF defenses always apply regardless.
	BlocklistDomains map[string]bool
	// AllowPrivateIPs disables the private/loopback/link-local/metadata IP deny
	// policy. Default false. Set true only in dev/tests (httptest binds 127.0.0.1).
	AllowPrivateIPs bool
	// AllowNonStandardPorts permits explicit ports other than 80 for HTTP and
	// 443 for HTTPS. Default false: limiting public origins to standard web ports
	// prevents the coordinator from becoming a public-network port scanner. Set
	// true only for controlled dev/test origins.
	AllowNonStandardPorts bool
}

// DefaultConfig returns the production defaults (feature enabled).
func DefaultConfig() Config {
	return Config{
		Enabled:               true,
		MaxFileBytes:          DefaultMaxFileBytes,
		MaxTotalBytes:         DefaultMaxTotalBytes,
		MaxParts:              DefaultMaxParts,
		FetchTimeout:          DefaultTimeout,
		TotalDeadline:         DefaultTotalDeadline,
		Concurrency:           DefaultConcurrency,
		GlobalConcurrency:     DefaultGlobalConcurrency,
		MaxImageMegapixels:    DefaultMaxImageMegapixels,
		BlocklistDomains:      map[string]bool{},
		AllowPrivateIPs:       false,
		AllowNonStandardPorts: false,
	}
}

// ConfigFromEnv builds a Config from EIGENINFERENCE_MEDIA_FETCH_* env vars,
// falling back to DefaultConfig for anything unset or unparseable.
func ConfigFromEnv() Config {
	c := DefaultConfig()
	c.Enabled = env.EnvBool(envEnabled, c.Enabled)
	c.MaxFileBytes = int64(env.EnvInt(envMaxFileBytes, int(c.MaxFileBytes)))
	c.MaxTotalBytes = int64(env.EnvInt(envMaxTotalBytes, int(c.MaxTotalBytes)))
	c.MaxParts = env.EnvInt(envMaxParts, c.MaxParts)
	c.FetchTimeout = time.Duration(env.EnvInt(envTimeoutMS, int(c.FetchTimeout/time.Millisecond))) * time.Millisecond
	c.TotalDeadline = time.Duration(env.EnvInt(envTotalDeadline, int(c.TotalDeadline/time.Millisecond))) * time.Millisecond
	c.Concurrency = env.EnvInt(envConcurrency, c.Concurrency)
	c.GlobalConcurrency = env.EnvInt(envGlobalConc, c.GlobalConcurrency)
	c.MaxImageMegapixels = env.EnvInt(envMaxMegapixels, c.MaxImageMegapixels)
	c.BlocklistDomains = parseBlocklist(env.EnvOr(envBlocklist, ""))
	c.AllowPrivateIPs = env.EnvBool(envAllowPrivateIP, c.AllowPrivateIPs)
	c.AllowNonStandardPorts = env.EnvBool(envAllowOtherPorts, c.AllowNonStandardPorts)
	return c.sanitized()
}

// sanitized clamps nonsensical values to safe defaults so a misconfigured env
// can't disable a cap (e.g. MaxParts<=0 would otherwise admit unbounded fetches).
// MaxImageMegapixels is exempt: 0 is a meaningful "coordinator check off" value
// (the provider's own pixel cap still applies), so only negatives are clamped.
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
	if c.GlobalConcurrency <= 0 {
		c.GlobalConcurrency = DefaultGlobalConcurrency
	}
	if c.MaxImageMegapixels < 0 {
		c.MaxImageMegapixels = DefaultMaxImageMegapixels
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
