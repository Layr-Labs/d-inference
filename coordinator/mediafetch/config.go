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
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Environment variable names (EIGENINFERENCE_ prefix, per coordinator/env).
const (
	envEnabled         = env.EnvPrefix + "_MEDIA_FETCH_ENABLED"
	envMaxFileBytes    = env.EnvPrefix + "_MEDIA_FETCH_MAX_FILE_BYTES"
	envMaxTotalBytes   = env.EnvPrefix + "_MEDIA_FETCH_MAX_TOTAL_BYTES"
	envTimeoutMS       = env.EnvPrefix + "_MEDIA_FETCH_TIMEOUT_MS"
	envTotalDeadline   = env.EnvPrefix + "_MEDIA_FETCH_TOTAL_DEADLINE_MS"
	envGlobalConc      = env.EnvPrefix + "_MEDIA_FETCH_GLOBAL_CONCURRENCY"
	envMaxMegapixels   = env.EnvPrefix + "_MEDIA_FETCH_MAX_IMAGE_MEGAPIXELS"
	envBlocklist       = env.EnvPrefix + "_MEDIA_FETCH_BLOCKLIST_DOMAINS"
	envAllowPrivateIP  = env.EnvPrefix + "_MEDIA_FETCH_ALLOW_PRIVATE_IPS"
	envAllowOtherPorts = env.EnvPrefix + "_MEDIA_FETCH_ALLOW_NONSTANDARD_PORTS"
)

// Defaults. The byte caps are reconciled against the coordinator's own 16 MiB
// forwarded-body cap (api.maxInferenceBodyBytes), which binds before the
// provider's 32 MiB frame. Raw media inflates ~1.37x as base64, so a 10 MiB
// aggregate raw cap inlines to ~13.3 MiB and leaves ~2.7 MiB for the rest of the
// request — a valid request is never fetched only to be rejected afterwards.
//
// MaxInlinedBytes bounds the same 16 MiB from the other side: duplicate parts
// sharing one URL are fetched once but written back to EVERY location, and the
// raw caps cannot see that multiplication.
//
// MaxImageMegapixels mirrors the provider's DARKBLOOM_MAX_IMAGE_MEGAPIXELS
// (100 MP, header-read) so pixel bombs die here, not across the fleet.
const (
	DefaultMaxFileBytes       int64 = 8 << 20  // 8 MiB per fetched file
	DefaultMaxTotalBytes      int64 = 10 << 20 // 10 MiB aggregate raw media/request (~13.3 MiB inlined)
	DefaultMaxInlinedBytes    int64 = 16 << 20 // matches api.maxInferenceBodyBytes (post-inline projection cap)
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
	// MaxInlinedBytes caps the projected size of the inlined media once every
	// data: URI has been written to every request location that references it
	// (locations × data-URI size). Unlike MaxTotalBytes this counts duplicate
	// targets, which multiply one fetch into many copies of the same base64 blob.
	//
	// Compile-time constant, deliberately not an env knob: it is protocol-derived,
	// mirroring api.maxInferenceBodyBytes (the coordinator's own forwarded-body
	// cap). Tuning it independently would only move where an oversized request
	// fails, not whether it fails.
	MaxInlinedBytes int64
	// MaxParts caps the number of remote media URLs fetched per request.
	//
	// Compile-time constant, deliberately not an env knob: 8 is matched to the
	// provider's videos-per-request cap, so changing one side just desyncs the
	// coordinator from the provider that has to accept the result.
	MaxParts int
	// FetchTimeout bounds a single fetch (connect + read), independent of the
	// request's TTFT deadline so a slow origin fails at the coordinator rather
	// than starving the provider.
	FetchTimeout time.Duration
	// TotalDeadline bounds the whole resolution step across all parts.
	TotalDeadline time.Duration
	// Concurrency is the per-request fetch worker-pool size.
	//
	// Compile-time constant, deliberately not an env knob: per-request fan-out is
	// not a useful capacity lever (a request has at most MaxParts parts). The
	// process-wide bound on outbound sockets is GlobalConcurrency, which is.
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
	// malformedEnv names every EIGENINFERENCE_MEDIA_FETCH_* variable that was SET
	// but could not be parsed. The shared env helpers fall back silently on a
	// parse error, which is the right call for a tuning knob and the wrong one
	// for a kill switch: `ENABLED=flase` typed during an incident would fall back
	// to the compiled default (true) and keep fetching. ConfigFromEnv records
	// those keys here and Check reports them, so the boot fails instead.
	malformedEnv []string
}

// envBool reads a boolean env var, recording the key when it is set but
// unparseable instead of silently falling back to the compiled default.
func (c *Config) envBool(key string, fallback bool) bool {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		c.malformedEnv = append(c.malformedEnv, key)
		return fallback
	}
	return b
}

// envInt reads an integer env var, recording the key when it is set but
// unparseable instead of silently falling back to the compiled default.
func (c *Config) envInt(key string, fallback int) int {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		c.malformedEnv = append(c.malformedEnv, key)
		return fallback
	}
	return n
}

// DefaultConfig returns the production defaults (feature enabled).
func DefaultConfig() Config {
	return Config{
		Enabled:               true,
		MaxFileBytes:          DefaultMaxFileBytes,
		MaxTotalBytes:         DefaultMaxTotalBytes,
		MaxInlinedBytes:       DefaultMaxInlinedBytes,
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
// falling back to DefaultConfig for anything unset.
//
// The result is deliberately NOT sanitized: it is the raw operator intent, so
// AppConfig.Check can fail the boot on a bad value instead of silently serving a
// default nobody asked for. Both failure shapes are covered — an out-of-range
// value (MAX_TOTAL_BYTES=0) trips Check's bounds, and a value that is set but
// unparseable (ENABLED=flase, TIMEOUT_MS=fast) is recorded in malformedEnv and
// trips Check too, because a silently-ignored kill switch is exactly the failure
// an operator cannot afford mid-incident. NewResolver clamps whatever reaches
// it, so a Resolver is safe either way.
func ConfigFromEnv() Config {
	c := DefaultConfig()
	c.Enabled = c.envBool(envEnabled, c.Enabled)
	c.MaxFileBytes = int64(c.envInt(envMaxFileBytes, int(c.MaxFileBytes)))
	c.MaxTotalBytes = int64(c.envInt(envMaxTotalBytes, int(c.MaxTotalBytes)))
	c.FetchTimeout = time.Duration(c.envInt(envTimeoutMS, int(c.FetchTimeout/time.Millisecond))) * time.Millisecond
	c.TotalDeadline = time.Duration(c.envInt(envTotalDeadline, int(c.TotalDeadline/time.Millisecond))) * time.Millisecond
	c.GlobalConcurrency = c.envInt(envGlobalConc, c.GlobalConcurrency)
	c.MaxImageMegapixels = c.envInt(envMaxMegapixels, c.MaxImageMegapixels)
	c.BlocklistDomains = parseBlocklist(env.EnvOr(envBlocklist, ""))
	c.AllowPrivateIPs = c.envBool(envAllowPrivateIP, c.AllowPrivateIPs)
	c.AllowNonStandardPorts = c.envBool(envAllowOtherPorts, c.AllowNonStandardPorts)
	return c
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
	if c.MaxInlinedBytes <= 0 {
		c.MaxInlinedBytes = DefaultMaxInlinedBytes
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

// parseBlocklist turns a comma-separated domain list into a canonicalized set.
// Entries go through the same canonicalHost normalization hostAllowed applies to
// request hosts (lowercase, UTS-46 IDNA, leading/trailing dots trimmed), so
// neither the FQDN spelling "evil.com." nor the conventional wildcard spelling
// ".evil.com" nor a Unicode homoglyph separator can store a key that never
// matches.
func parseBlocklist(csv string) map[string]bool {
	out := map[string]bool{}
	for _, raw := range strings.Split(csv, ",") {
		if h := canonicalHost(strings.TrimSpace(raw)); h != "" {
			out[h] = true
		}
	}
	return out
}

// Check validates the configuration, rejecting bounds that would disable a cap
// outright. sanitized() silently clamps the same fields so a running Resolver is
// always safe; Check is the loud, boot-time counterpart that makes an operator
// typo fail the process instead of quietly reverting to a default the operator
// did not ask for.
//
// AllowPrivateIPs / AllowNonStandardPorts are deliberately NOT errors: dev and
// single-host deployments legitimately set them. NewResolver logs a boot WARN
// for those instead.
func (c Config) Check() error {
	// Reported first: a key that was set but unparseable means the operator asked
	// for something the process did not do, which matters most for the ENABLED
	// kill switch — a silent fallback there keeps fetching during an incident.
	if len(c.malformedEnv) > 0 {
		return fmt.Errorf("mediafetch: unparseable value(s) for %s", strings.Join(c.malformedEnv, ", "))
	}
	// One row per numeric bound, so a new field is a new line rather than a new
	// branch. env is empty for the fields that are compile-time constants with no
	// operator-facing variable; those print without a dangling parenthetical.
	for _, rule := range []struct {
		field string
		env   string
		bound string
		ok    bool
		got   any
	}{
		{"MaxFileBytes", envMaxFileBytes, "> 0", c.MaxFileBytes > 0, c.MaxFileBytes},
		{"MaxTotalBytes", envMaxTotalBytes, "> 0", c.MaxTotalBytes > 0, c.MaxTotalBytes},
		{"MaxInlinedBytes", "", "> 0", c.MaxInlinedBytes > 0, c.MaxInlinedBytes},
		{"MaxParts", "", "> 0", c.MaxParts > 0, c.MaxParts},
		{"FetchTimeout", envTimeoutMS, "> 0", c.FetchTimeout > 0, c.FetchTimeout},
		{"TotalDeadline", envTotalDeadline, "> 0", c.TotalDeadline > 0, c.TotalDeadline},
		{"Concurrency", "", "> 0", c.Concurrency > 0, c.Concurrency},
		{"GlobalConcurrency", envGlobalConc, "> 0", c.GlobalConcurrency > 0, c.GlobalConcurrency},
		// >= 0, not > 0: 0 is the documented "coordinator-side pixel check off"
		// value (the provider's own pre-raster cap still applies). A negative,
		// though, parses fine and would be silently reverted to the default by
		// sanitized() — exactly the quiet substitution Check exists to catch.
		{"MaxImageMegapixels", envMaxMegapixels, ">= 0", c.MaxImageMegapixels >= 0, c.MaxImageMegapixels},
	} {
		if rule.ok {
			continue
		}
		if rule.env == "" {
			return fmt.Errorf("mediafetch: %s must be %s, got %v", rule.field, rule.bound, rule.got)
		}
		return fmt.Errorf("mediafetch: %s must be %s (%s), got %v", rule.field, rule.bound, rule.env, rule.got)
	}
	// Not a per-field bound: the two caps are individually fine and only their
	// ordering is wrong.
	if c.MaxFileBytes > c.MaxTotalBytes {
		return fmt.Errorf("mediafetch: MaxFileBytes (%d) must be <= MaxTotalBytes (%d); the aggregate per-request budget is authoritative",
			c.MaxFileBytes, c.MaxTotalBytes)
	}
	return nil
}
