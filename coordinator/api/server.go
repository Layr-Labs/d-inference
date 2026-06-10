// Package api provides the HTTP and WebSocket server for the Darkbloom coordinator.
//
// This package is the network-facing layer of the coordinator. It handles:
//   - Consumer HTTP endpoints (OpenAI-compatible chat completions, model listing)
//   - Provider WebSocket connections (registration, heartbeats, inference relay)
//   - Payment endpoints (deposit, balance, usage)
//   - Authentication via API keys (Bearer token)
//   - CORS middleware for development
//   - Request logging
//
// The coordinator runs in a GCP Confidential VM (AMD SEV-SNP). Consumer traffic
// arrives over HTTPS/TLS. The coordinator reads requests for routing but never
// logs prompt content.
package api

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"crypto/x509"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
)

// apiKeyCacheEntry stores the authenticated key record for a single raw API
// key. Cached to skip DB round trips on repeat requests with the same key. A
// nil key means the token is known-invalid (negative cache).
type apiKeyCacheEntry struct {
	key      *store.APIKey
	cachedAt time.Time
	gen      uint64 // cache generation this entry was stored under
}

const (
	apiKeyCacheTTL     = 60 * time.Second
	apiKeyCacheMaxSize = 1000
)

// contextKey is an unexported type for context keys in this package.
// Using a distinct type prevents collisions with context keys from other packages.
type contextKey int

const (
	ctxKeyConsumer contextKey = iota
	ctxKeyRequestID
	ctxKeyAPIKey
)

// requestIDFromContext returns the per-request correlation ID set by
// the logging middleware. Empty if the request didn't pass through the
// middleware (e.g. raw test handlers).
func requestIDFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyRequestID).(string); ok {
		return v
	}
	return ""
}

// cryptoRand is a small wrapper to read random bytes. Defined as a var
// so tests can stub it if needed; production uses crypto/rand.Read.
var cryptoRand = rand.Read

// consumerKeyFromContext retrieves the authenticated consumer's API key
// from the request context. The key is stored by requireAuth middleware
// and used as the consumer's identity for billing and usage tracking.
func consumerKeyFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(ctxKeyConsumer).(string); ok {
		return v
	}
	return ""
}

// apiKeyFromContext returns the authenticated API key record set by requireAuth,
// carrying the per-key limits used by the request path. Returns nil for
// non-API-key auth (Privy JWT, admin key) and for account-scoped/legacy keys
// without per-key metadata.
func apiKeyFromContext(ctx context.Context) *store.APIKey {
	if v, ok := ctx.Value(ctxKeyAPIKey).(*store.APIKey); ok {
		return v
	}
	return nil
}

// keyIDFromContext returns the public ID of the authenticated API key, or ""
// for account-scoped/legacy callers. Used to stamp per-key usage attribution
// onto in-flight requests.
func keyIDFromContext(ctx context.Context) string {
	if k := apiKeyFromContext(ctx); k != nil {
		return k.ID
	}
	return ""
}

// keyLimitMicroFromContext / keyLimitResetFromContext expose the calling key's
// spend cap so it can be stamped onto a PendingRequest and re-enforced when a
// provider's custom price tops up the reservation. nil = no per-key cap.
func keyLimitMicroFromContext(ctx context.Context) *int64 {
	if k := apiKeyFromContext(ctx); k != nil {
		return k.LimitMicroUSD
	}
	return nil
}

func keyLimitResetFromContext(ctx context.Context) string {
	if k := apiKeyFromContext(ctx); k != nil {
		return k.LimitReset
	}
	return ""
}

// LatestProviderVersion is the fallback version returned only when no
// release has been registered in the store (e.g. in-memory dev setups).
// Production reads the latest version from the releases table.
//
// 0.6.0 is the APNs code-identity / VLM-routing / graceful-update release.
// Keep this fallback in sync with ProviderCore.version so dev/in-memory
// coordinators advertise the same floor as the Swift binary they expect.
var LatestProviderVersion = "0.6.2"

// minProviderVersionForDesiredModels is the first provider version whose Swift
// runtime understands the desired_models message. The coordinator must NOT send
// desired_models to any provider below this version (or on a non-Swift backend):
// a pre-feature provider's strict decoder throws on unknown message types and
// would disconnect. KEEP THIS IN SYNC with the release that ships Swift
// desired_models support (ProviderCore.version at that cut).
const minProviderVersionForDesiredModels = "0.5.17"

// latestReleasedVersion returns the highest active release version from
// the store, falling back to the hardcoded LatestProviderVersion when
// no release record exists.
func (s *Server) latestReleasedVersion() string {
	if release := s.store.GetLatestRelease("macos-arm64"); release != nil {
		return release.Version
	}
	return LatestProviderVersion
}

// Server is the main HTTP/WS server for the coordinator. It ties together
// the provider registry, key store, payment ledger, billing service, and HTTP routing.
type Server struct {
	registry               *registry.Registry
	store                  store.Store
	ledger                 *payments.Ledger
	billing                *billing.Service
	logger                 *slog.Logger
	mux                    *http.ServeMux
	challengeInterval      time.Duration             // 0 means use DefaultChallengeInterval
	skipChallenge          bool                      // if true, skip attestation challenges entirely (testing only)
	privyAuth              *auth.PrivyAuth           // Privy JWT authentication (nil if not configured)
	adminEmails            map[string]bool           // emails that have admin access
	adminKey               string                    // EIGENINFERENCE_ADMIN_KEY for admin endpoints
	mdmClient              *mdm.Client               // MicroMDM client for provider security verification
	mdmWebhookSecret       string                    // optional shared secret MicroMDM must present on the webhook
	stepCARootCert         *x509.Certificate         // step-ca root CA for ACME cert verification
	stepCAIntermediateCert *x509.Certificate         // step-ca intermediate CA
	profileSigner          *profilesign.Signer       // CMS signer for the /v1/enroll .mobileconfig (nil = serve unsigned)
	codeAttestor           apns.CodeIdentityAttestor // APNs code-identity attestor (nil = disabled; v0.6.0)
	codeAttestThrottle     *codeAttestThrottle       // per-device APNs push budget + reuse cache (v0.6.0)

	// knownBinaryHashes is the set of accepted provider binary SHA-256 hashes.
	// When binaryHashPolicyConfigured is true, providers whose binary hash is
	// missing or doesn't match are rejected.
	// Auto-populated from active releases via SyncBinaryHashes().
	binaryHashPolicyMu                sync.RWMutex
	knownBinaryHashes                 map[string]bool
	manualKnownBinaryHashes           map[string]bool
	releaseKnownBinaryHashes          map[string]bool
	manualBinaryHashPolicyConfigured  bool
	releaseBinaryHashPolicyConfigured bool
	binaryHashPolicyConfigured        bool

	// binaryHashEnforce gates whether a self-reported binaryHash mismatch actually
	// DEROUTES a provider. Default false as of v0.6.0: binaryHash is self-reported
	// (worthless against a malicious provider) and is demoted to drift telemetry —
	// APNs code-identity attestation is the real code-identity signal. The policy
	// machinery is retained for drift comparison and rollback
	// (EIGENINFERENCE_BINARYHASH_ENFORCE=true).
	binaryHashEnforce bool

	// knownRuntimeManifest holds accepted runtime component hashes.
	// When set, providers whose runtime hashes don't match are marked as
	// unverified and excluded from routing (but not disconnected).
	knownRuntimeManifest *RuntimeManifest

	// minProviderVersion is the minimum provider version accepted for routing.
	// Providers below this version are excluded and told to update.
	// Set from EIGENINFERENCE_MIN_PROVIDER_VERSION env var or derived from latest release.
	minProviderVersion string

	// releaseKey is a scoped credential for the GitHub Action to register releases.
	// It can only POST /v1/releases — no admin access.
	releaseKey string

	// consoleURL is the frontend URL (e.g. "https://console.darkbloom.dev").
	// Used for device auth verification_uri so the browser opens the console, not the coordinator.
	consoleURL string

	// baseURL is the public URL clients reach this coordinator at
	// (e.g. "https://api.darkbloom.dev" for prod, "https://api.dev.darkbloom.xyz" for dev).
	// Substituted into the embedded install.sh at serve time so the same binary
	// can serve both environments. Falls back to "https://" + request.Host when empty.
	baseURL string

	// r2CDNURL is the public R2 bucket URL that providers pull release artifacts
	// from (e.g. "https://models.darkbloom.ai").
	// Set from EIGENINFERENCE_R2_CDN_URL env var. Empty disables CDN metadata.
	r2CDNURL string

	// r2SitePackagesCDNURL is the R2 bucket URL for site packages (e.g.
	// auto-update manifests). Set from EIGENINFERENCE_R2_SITE_PACKAGES_CDN_URL.
	r2SitePackagesCDNURL string

	// corsOrigin is the allowed CORS origin (e.g. "https://console.darkbloom.dev").
	// Set from CORS_ORIGIN env var. Empty defaults to the production console domain.
	corsOrigin string

	// storedProviders is a lookup table of persisted provider records, indexed
	// by serial number and SE public key. When a provider reconnects after a
	// coordinator restart, this table is checked to restore trust/reputation.
	// Populated once at startup from the store.
	storedProviders map[string]*store.ProviderRecord

	// geoResolver resolves provider and consumer request locations from IP
	// addresses or trusted reverse-proxy headers. Nil when GeoIP is not configured.
	geoResolver providerGeoResolver

	// coordinatorKey is the long-lived X25519 keypair used to receive sealed
	// requests from senders. Set via SetCoordinatorKey. nil disables the
	// /v1/encryption-key endpoint and the sealed-request middleware.
	coordinatorKey *e2e.CoordinatorKey

	// metrics is the in-process metrics registry exposed via /v1/admin/metrics
	// and used by internal counters/histograms. Never nil.
	metrics *Metrics

	// telemetryLimiter throttles telemetry ingestion per submitter.
	telemetryLimiter *telemetryLimiter

	// readCache memoizes pre-serialized JSON for read-heavy aggregation
	// endpoints (stats, leaderboard, model catalog, etc.). TTLs are
	// per-key. Never nil.
	readCache *ttlCache

	// emitter writes coordinator-side telemetry events (panics, handler
	// failures, attestation failures, etc.). Set via SetEmitter; nil before
	// main.go wires it up.
	emitter *telemetry.Emitter

	// dd is the Datadog integration client for DogStatsD metrics and
	// Logs API event forwarding. Nil when DD is not configured.
	dd *datadog.Client

	// pendingACME holds the connect-time ACME (mTLS device-cert) verification
	// result per provider so the trust upgrade can be retried after the first
	// passing challenge. applyACMETrust runs at registration BEFORE the first
	// challenge response sets AttestationResult, so its binding checks fail
	// purely on ordering and the provider stays self_signed forever. Cleared on
	// successful upgrade or disconnect.
	pendingACMEMu sync.Mutex
	pendingACME   map[string]*ACMEVerificationResult

	// apiKeyCache memoizes ValidateKeyFull results so repeated requests
	// with the same API key skip the DB round trip. Entries expire after
	// apiKeyCacheTTL. Bounded at apiKeyCacheMaxSize entries.
	apiKeyCacheMu sync.RWMutex
	apiKeyCache   map[string]apiKeyCacheEntry
	// apiKeyCacheGen is bumped on every key mutation. A cached entry is only
	// honored when its gen matches, so a single bump atomically invalidates the
	// whole cache and closes the read-stale-after-mutation race.
	apiKeyCacheGen uint64

	// rateLimiter applies per-account token-bucket rate limits to consumer
	// inference endpoints. Nil means unlimited (compatibility with old call
	// sites and tests). Set via SetRateLimiter.
	rateLimiter *ratelimit.Limiter

	// financialRateLimiter is a separate, stricter limiter for endpoints
	// that touch on-chain state or mutate balances (deposit, withdraw, key
	// creation, referral apply, invite redemption). These are higher-value
	// targets for spam/abuse than inference, so we throttle them harder.
	// Nil means unlimited.
	financialRateLimiter *ratelimit.Limiter

	// serviceRateLimiter applies an elevated per-account limit to trusted
	// service accounts (store.RoleService), e.g. an upstream aggregator like
	// OpenRouter that fans out many end-users behind one key. When nil,
	// service accounts bypass rate limiting entirely.
	serviceRateLimiter *ratelimit.Limiter

	// consumerTokenLimiter / serviceTokenLimiter enforce per-account input
	// (ITPM) and output (OTPM) token-per-minute limits on inference endpoints,
	// the industry-standard token throttle alongside RPM. Nil means no token
	// limiting for that tier. Service accounts use serviceTokenLimiter.
	consumerTokenLimiter *ratelimit.TokenLimiter
	serviceTokenLimiter  *ratelimit.TokenLimiter

	// keyRPMLimiter / keyTokenLimiter enforce PER-KEY rate overrides (each key
	// may carry a different ceiling) on top of the per-account limiters above.
	// They only act when a key sets RPMLimit / ITPMLimit / OTPMLimit; otherwise
	// the key inherits the account-level limits. Nil disables per-key limiting.
	keyRPMLimiter   *ratelimit.Limiter
	keyTokenLimiter *ratelimit.KeyTokenLimiter
}

// SetRateLimiter configures the per-account rate limiter applied to
// consumer inference endpoints. Pass nil to disable.
func (s *Server) SetRateLimiter(rl *ratelimit.Limiter) {
	s.rateLimiter = rl
}

// SetFinancialRateLimiter configures a stricter per-account limiter for
// balance-mutating endpoints. Pass nil to disable.
func (s *Server) SetFinancialRateLimiter(rl *ratelimit.Limiter) {
	s.financialRateLimiter = rl
}

// SetServiceRateLimiter configures the elevated limiter used for service-role
// accounts (e.g. OpenRouter). Pass nil to let service accounts bypass limits.
func (s *Server) SetServiceRateLimiter(rl *ratelimit.Limiter) {
	s.serviceRateLimiter = rl
}

// SetTokenLimiters configures the per-account input/output token-per-minute
// limiters for the consumer and service tiers. Pass nil for a tier to disable
// token limiting for it.
func (s *Server) SetTokenLimiters(consumer, service *ratelimit.TokenLimiter) {
	s.consumerTokenLimiter = consumer
	s.serviceTokenLimiter = service
}

// SetKeyLimiters configures the per-key (variable-rate) RPM and ITPM/OTPM
// limiters used for per-key overrides. Pass nil to disable per-key limiting.
func (s *Server) SetKeyLimiters(rpm *ratelimit.Limiter, tokens *ratelimit.KeyTokenLimiter) {
	s.keyRPMLimiter = rpm
	s.keyTokenLimiter = tokens
}

// applyTokenRateLimit enforces per-account ITPM/OTPM limits at request
// admission using the upfront input estimate and the bounded max_tokens
// (OpenAI-style upfront charge). It returns true when the request may proceed;
// on rejection it writes a 429 naming the tripped dimension (with Retry-After)
// and returns false. Admin bypasses. Standard x-ratelimit-*-{input,output}-tokens
// headers are set on both success and rejection.
func (s *Server) applyTokenRateLimit(w http.ResponseWriter, r *http.Request, inputTokens, outputTokens int) bool {
	accountID := consumerKeyFromContext(r.Context())
	if accountID == "admin" {
		return true
	}

	// Resolve the account-tier token limiter (nil = no account-level token limit
	// for this caller, e.g. a service account with no service token limiter).
	tl := s.consumerTokenLimiter
	tier := "consumer"
	if user := auth.UserFromContext(r.Context()); user != nil && user.Role == store.RoleService {
		if s.serviceTokenLimiter != nil {
			tl = s.serviceTokenLimiter
			tier = "service"
		} else {
			tl = nil
		}
	}

	keyID, inRPS, inBurst, outRPS, outBurst, keyEnforced := s.keyTokenParams(r)

	// Peek BOTH the per-key override and the account-level limiter before
	// consuming either. Only commit when both have capacity, so a rejection in
	// one limiter never debits the other (a per-key request that the account
	// bucket rejects must not drain the key's quota, and vice-versa).
	if keyEnforced {
		if ok, dim, retry := s.keyTokenLimiter.Peek(keyID, inputTokens, outputTokens, inRPS, inBurst, outRPS, outBurst); !ok {
			s.writeTokenRateLimited(w, "key", dim, retry)
			return false
		}
	}
	if tl != nil {
		if ok, dim, retry := tl.Peek(accountID, inputTokens, outputTokens); !ok {
			setTokenRateLimitHeaders(w, tl, accountID)
			s.writeTokenRateLimited(w, tier, dim, retry)
			return false
		}
	}

	// Both dimensions have capacity — commit to each.
	if keyEnforced {
		s.keyTokenLimiter.Commit(keyID, inputTokens, outputTokens, inRPS, inBurst, outRPS, outBurst)
	}
	if tl != nil {
		tl.Commit(accountID, inputTokens, outputTokens)
		setTokenRateLimitHeaders(w, tl, accountID)
	}
	return true
}

// writeTokenRateLimited writes a 429 for a token-dimension rejection with a
// Retry-After header and a dimension-specific message. tier is "consumer",
// "service", or "key".
func (s *Server) writeTokenRateLimited(w http.ResponseWriter, tier, dimension string, retryAfter time.Duration) {
	seconds := int(retryAfter.Seconds())
	if seconds < 1 {
		seconds = 1
	}
	w.Header().Set("Retry-After", strconv.Itoa(seconds))
	s.ddIncr("ratelimit.rejections", []string{"tier:" + tier, "dimension:" + dimension})
	msg := fmt.Sprintf("%s rate limit exceeded — retry after %ds", dimension, seconds)
	if tier == "key" {
		msg = fmt.Sprintf("API key %s rate limit exceeded — retry after %ds", dimension, seconds)
	}
	writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded", msg, withCode("rate_limit_exceeded")))
}

// setTokenRateLimitHeaders emits the standard input/output token rate-limit
// headers from the limiter's current state.
func setTokenRateLimitHeaders(w http.ResponseWriter, tl *ratelimit.TokenLimiter, accountID string) {
	h := w.Header()
	if in, ok := tl.InputStat(accountID); ok {
		h.Set("x-ratelimit-limit-input-tokens", strconv.Itoa(in.LimitPerMinute))
		h.Set("x-ratelimit-remaining-input-tokens", strconv.Itoa(in.Remaining))
		h.Set("x-ratelimit-reset-input-tokens", strconv.Itoa(in.ResetSeconds)+"s")
	}
	if out, ok := tl.OutputStat(accountID); ok {
		h.Set("x-ratelimit-limit-output-tokens", strconv.Itoa(out.LimitPerMinute))
		h.Set("x-ratelimit-remaining-output-tokens", strconv.Itoa(out.Remaining))
		h.Set("x-ratelimit-reset-output-tokens", strconv.Itoa(out.ResetSeconds)+"s")
	}
}

// applyKeyRPMLimit enforces a per-key requests-per-minute override when the
// authenticated key sets RPMLimit. Returns true (allow) when no key override
// applies. On rejection it writes a 429 with Retry-After and returns false.
func (s *Server) applyKeyRPMLimit(w http.ResponseWriter, r *http.Request) bool {
	if s.keyRPMLimiter == nil {
		return true
	}
	k := apiKeyFromContext(r.Context())
	if k == nil || k.ID == "" || k.RPMLimit == nil || *k.RPMLimit <= 0 {
		return true
	}
	rpm := *k.RPMLimit
	burst := int(rpm)
	if burst < 1 {
		burst = 1
	}
	allowed, retryAfter := s.keyRPMLimiter.AllowNWithRate(k.ID, 1, float64(rpm)/60.0, burst)
	if !allowed {
		seconds := int(retryAfter.Seconds())
		if seconds < 1 {
			seconds = 1
		}
		w.Header().Set("Retry-After", strconv.Itoa(seconds))
		s.ddIncr("ratelimit.rejections", []string{"tier:key", "dimension:requests"})
		writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
			fmt.Sprintf("API key request rate limit exceeded — retry after %ds", seconds),
			withCode("rate_limit_exceeded")))
		return false
	}
	return true
}

// keyTokenParams resolves the per-key ITPM/OTPM override for the calling key.
// enforced is false when no per-key token limit applies (no key, no limiter, or
// no override set), in which case the other return values are zero.
func (s *Server) keyTokenParams(r *http.Request) (keyID string, inRPS float64, inBurst int, outRPS float64, outBurst int, enforced bool) {
	if s.keyTokenLimiter == nil {
		return "", 0, 0, 0, 0, false
	}
	k := apiKeyFromContext(r.Context())
	if k == nil || k.ID == "" {
		return "", 0, 0, 0, 0, false
	}
	if k.ITPMLimit != nil && *k.ITPMLimit > 0 {
		inRPS = float64(*k.ITPMLimit) / 60.0
		inBurst = int(*k.ITPMLimit)
	}
	if k.OTPMLimit != nil && *k.OTPMLimit > 0 {
		outRPS = float64(*k.OTPMLimit) / 60.0
		outBurst = int(*k.OTPMLimit)
	}
	if inRPS <= 0 && outRPS <= 0 {
		return "", 0, 0, 0, 0, false
	}
	return k.ID, inRPS, inBurst, outRPS, outBurst, true
}

// setRequestRateLimitHeaders emits the standard request-dimension rate-limit
// headers.
func setRequestRateLimitHeaders(w http.ResponseWriter, st ratelimit.Stat) {
	h := w.Header()
	h.Set("x-ratelimit-limit-requests", strconv.Itoa(st.LimitPerMinute))
	h.Set("x-ratelimit-remaining-requests", strconv.Itoa(st.Remaining))
	h.Set("x-ratelimit-reset-requests", strconv.Itoa(st.ResetSeconds)+"s")
}

// NewServer creates a configured Server with all routes mounted.
func NewServer(reg *registry.Registry, st store.Store, cfg ServerConfig, logger *slog.Logger) *Server {
	// Wire the store into the registry for provider fleet persistence.
	reg.SetStore(st)

	s := &Server{
		registry:             reg,
		store:                st,
		ledger:               payments.NewLedger(st),
		logger:               logger,
		mux:                  http.NewServeMux(),
		knownRuntimeManifest: &RuntimeManifest{},
		metrics:              NewMetrics(),
		telemetryLimiter:     newTelemetryLimiter(),
		readCache:            newTTLCache(),
		geoResolver:          newProviderGeoResolverFromEnv(logger),
		apiKeyCache:          make(map[string]apiKeyCacheEntry),
		pendingACME:          make(map[string]*ACMEVerificationResult),
		codeAttestThrottle:   newCodeAttestThrottle(),
	}
	s.registerDefaultGauges()
	s.routes()

	// Load stored provider records into a lookup table for matching
	// reconnecting providers to their persisted state.
	s.storedProviders = reg.LoadStoredProviders()
	// Apply server configuration from ServerConfig.
	// TODO(auth): storing admin emails in the server struct is an antipattern.
	// Move admin verification to an external auth service (Privy or IDP) so that
	// the server doesn't need to hold email state.
	s.adminKey = cfg.AdminKey
	if len(cfg.AdminEmails) > 0 {
		s.adminEmails = make(map[string]bool)
		for _, e := range cfg.AdminEmails {
			s.adminEmails[strings.ToLower(strings.TrimSpace(e))] = true
		}
	}
	s.consoleURL = cfg.ConsoleURL
	s.corsOrigin = cfg.CORSOrigin
	s.baseURL = strings.TrimRight(cfg.BaseURL, "/")
	s.minProviderVersion = strings.TrimSpace(cfg.MinProviderVersion)
	s.r2CDNURL = strings.TrimRight(cfg.R2CDNURL, "/")
	s.r2SitePackagesCDNURL = strings.TrimRight(cfg.R2SitePackagesCDNURL, "/")
	s.releaseKey = cfg.ReleaseKey

	return s
}

// SetAdminKey configures the admin API key for admin-only endpoints.
func (s *Server) SetAdminKey(key string) {
	s.adminKey = key
}

// SetMinProviderVersion sets the minimum provider version for routing.
func (s *Server) SetMinProviderVersion(v string) {
	s.minProviderVersion = strings.TrimSpace(v)
}

// SetBaseURL sets the coordinator's public URL (used to template install.sh).
// Pass the canonical origin with no trailing slash, e.g. "https://api.darkbloom.dev".
// If unset, the install.sh handler derives a URL from the request's Host header.
func (s *Server) SetBaseURL(url string) {
	s.baseURL = strings.TrimRight(url, "/")
}

// SetR2CDNURL sets the public R2 bucket URL that install.sh substitutes as
// the model/template/release download origin. If unset, install.sh keeps the
// placeholder — providers will fail to pull artifacts, making the misconfig
// loud instead of silent.
func (s *Server) SetR2CDNURL(url string) {
	s.r2CDNURL = strings.TrimRight(url, "/")
}

// SetEmitter wires the coordinator-side telemetry emitter. Call once at boot.
func (s *Server) SetEmitter(e *telemetry.Emitter) {
	s.emitter = e
}

// SetDatadog wires the Datadog client for DogStatsD metrics and Logs API forwarding.
func (s *Server) SetDatadog(dd *datadog.Client) {
	s.dd = dd
}

// Datadog returns the Datadog client (or nil). Exposed so main.go and the
// telemetry emitter can share the same client.
func (s *Server) Datadog() *datadog.Client {
	return s.dd
}

// Metrics returns the in-process metrics registry so cmd/coordinator can
// expose it to the telemetry emitter and other integrations.
func (s *Server) Metrics() *Metrics {
	return s.metrics
}

// emit is an internal convenience that funnels events through the emitter if
// one has been wired up. No-op otherwise — telemetry must never affect control
// flow.
func (s *Server) emit(ctx context.Context, severity protocol.TelemetrySeverity, kind protocol.TelemetryKind, message string, fields map[string]any) {
	if s.emitter == nil {
		return
	}
	s.emitter.Emit(telemetry.Event{
		Severity: severity,
		Kind:     kind,
		Message:  message,
		Fields:   fields,
	})
}

// emitRequest is like emit but preserves a request_id for correlation.
func (s *Server) emitRequest(ctx context.Context, severity protocol.TelemetrySeverity, requestID, message string, fields map[string]any) {
	if s.emitter == nil {
		return
	}
	s.emitter.Emit(telemetry.Event{
		Severity:  severity,
		Kind:      protocol.KindInferenceError,
		Message:   message,
		Fields:    fields,
		RequestID: requestID,
	})
}

// ddIncr increments a DogStatsD counter. No-op if DD is not configured.
func (s *Server) ddIncr(name string, tags []string) {
	if s.dd != nil {
		s.dd.Incr(name, tags)
	}
}

// ddCount increments a DogStatsD counter by the given value. No-op if DD is not configured.
func (s *Server) ddCount(name string, value int64, tags []string) {
	if s.dd != nil {
		s.dd.Count(name, value, tags)
	}
}

// ddHistogram records a DogStatsD histogram value. No-op if DD is not configured.
func (s *Server) ddHistogram(name string, value float64, tags []string) {
	if s.dd != nil {
		s.dd.Histogram(name, value, tags)
	}
}

// ddGauge sets a DogStatsD gauge value. No-op if DD is not configured.
func (s *Server) ddGauge(name string, value float64, tags []string) {
	if s.dd != nil {
		s.dd.Gauge(name, value, tags)
	}
}

func (s *Server) emitPanic(ctx context.Context, message, stack string, fields map[string]any) {
	if s.emitter == nil {
		return
	}
	s.emitter.Emit(telemetry.Event{
		Severity: protocol.SeverityFatal,
		Kind:     protocol.KindPanic,
		Message:  message,
		Fields:   fields,
		Stack:    stack,
	})
}

// SetStepCACerts configures the step-ca CA certificates for ACME client cert verification.
func (s *Server) SetStepCACerts(root, intermediate *x509.Certificate) {
	s.stepCARootCert = root
	s.stepCAIntermediateCert = intermediate
}

// SetProfileSigner configures the CMS signing identity used to sign the
// enrollment .mobileconfig served by /v1/enroll. When unset (nil), profiles are
// served unsigned (the historical behaviour).
func (s *Server) SetProfileSigner(signer *profilesign.Signer) {
	s.profileSigner = signer
}

// SetBilling configures the billing service for multi-chain payments and referrals.
func (s *Server) SetBilling(svc *billing.Service) {
	s.billing = svc
}

func (s *Server) Billing() *billing.Service {
	return s.billing
}

func (s *Server) SetChallengeInterval(d time.Duration) {
	s.challengeInterval = d
}

func (s *Server) SetSkipChallenge(skip bool) {
	s.skipChallenge = skip
}

// SetPrivyAuth configures Privy JWT authentication for consumer endpoints.
func (s *Server) SetPrivyAuth(pa *auth.PrivyAuth) {
	s.privyAuth = pa
}

// SetAdminEmails configures which Privy accounts have admin access.
func (s *Server) SetAdminEmails(emails []string) {
	s.adminEmails = make(map[string]bool, len(emails))
	for _, e := range emails {
		s.adminEmails[strings.ToLower(strings.TrimSpace(e))] = true
	}
}

// SetMDMClient configures the MicroMDM client for provider verification.
// When set, providers are verified against MDM on registration.
func (s *Server) SetMDMClient(client *mdm.Client) {
	s.mdmClient = client
}

// SetCodeAttestor wires the APNs code-identity attestor (v0.6.0). When set, the
// coordinator issues code-identity challenges and measures which providers pass —
// but enforcement (derouting un-attested providers) only begins once a deadline
// is reached (SetCodeAttestationDeadline). So configuring the attestor alone is
// SAFE: the fleet stays in grace/observe mode and keeps routing. Passing nil
// leaves the feature disabled. Call once during server setup, before providers
// connect.
func (s *Server) SetCodeAttestor(a apns.CodeIdentityAttestor) {
	s.codeAttestor = a
	s.registry.SetCodeAttestationConfigured(a != nil)
}

// SetCodeAttestationDeadline sets the instant at which code-identity attestation
// becomes mandatory for routing. Before it (or when zero) the coordinator runs in
// grace mode: it challenges providers but still routes un-attested ones, giving
// the fleet time to update to 0.6.0 and attest. Wire it from APNS_ENFORCE_AFTER.
func (s *Server) SetCodeAttestationDeadline(t time.Time) {
	s.registry.SetCodeAttestationDeadline(t)
}

// SetMDMWebhookSecret configures an optional shared secret that MicroMDM must
// present (as ?token= or the X-Webhook-Token header) when calling the webhook.
// When empty, the webhook relies solely on the solicited-command (CommandUUID)
// gate in the MDM client; when set, callers lacking the secret are rejected
// before the body is read. MicroMDM is co-located with the coordinator, so this
// secret never traverses the public network.
func (s *Server) SetMDMWebhookSecret(secret string) {
	s.mdmWebhookSecret = secret
}

// SyncModelCatalog reads active models from the store and updates the
// registry's model catalog. Call this at startup and after admin catalog changes.
func (s *Server) SyncModelCatalog() {
	registryRows, err := s.store.ListActiveModelRegistryWithError()
	if err != nil {
		s.logger.Error("model registry catalog sync failed", "error", err)
		return
	}
	entries := make([]registry.CatalogEntry, 0, len(registryRows))
	for _, row := range registryRows {
		if row.ActiveVersion == nil {
			continue
		}
		entries = append(entries, registry.CatalogEntry{
			ID:         row.ID,
			WeightHash: row.ActiveVersion.AggregateSHA256,
			SizeGB:     float64(row.ActiveVersion.TotalSizeBytes) / 1e9,
			MinRAMGB:   row.MinRAMGB,
		})
	}
	s.registry.SetModelCatalog(entries)
	s.logger.Info("model registry catalog synced to registry", "active_models", len(entries))

	s.syncModelAliases()
	s.invalidateCatalogCache()
}

// syncModelAliases loads public-alias → {desired, previous} build pointers from
// the store into the registry so consumer requests for an alias (e.g.
// "gemma-4-26b") resolve to a concrete build. Only active aliases with a
// non-empty desired build are installed.
func (s *Server) syncModelAliases() {
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		s.logger.Error("model alias sync failed", "error", err)
		return
	}
	resolved := make(map[string]registry.AliasTarget, len(aliases))
	for _, a := range aliases {
		if !a.Active || a.DesiredBuild == "" {
			continue
		}
		resolved[a.AliasID] = registry.AliasTarget{
			Desired:  a.DesiredBuild,
			Previous: a.PreviousBuild,
			Retired:  a.RetiredBuilds,
		}
	}
	s.registry.SetModelAliases(resolved)
	s.logger.Info("model aliases synced to registry", "active_aliases", len(resolved))
}

// invalidateCatalogCache removes all cached model catalog responses so the
// next request picks up any changes made by admin endpoints.
func (s *Server) invalidateCatalogCache() {
	if s.readCache == nil {
		return
	}
	s.readCache.Invalidate("models:catalog")
	s.readCache.Invalidate("models:catalog:text")
}

// SetKnownBinaryHashes configures the set of accepted provider binary hashes.
// SetBinaryHashEnforcement toggles whether a self-reported binaryHash mismatch
// deroutes a provider. Default false (v0.6.0): binaryHash is demoted to drift
// telemetry; APNs code-identity attestation is the real signal. Enable only for
// rollback or to test the legacy enforcement path.
func (s *Server) SetBinaryHashEnforcement(enabled bool) {
	s.binaryHashEnforce = enabled
}

// Providers whose binary SHA-256 doesn't match any known hash are rejected.
func (s *Server) SetKnownBinaryHashes(hashes []string) {
	normalized := normalizeKnownBinaryHashes(hashes, s.logger)

	s.binaryHashPolicyMu.Lock()
	defer s.binaryHashPolicyMu.Unlock()

	s.manualKnownBinaryHashes = normalized
	s.manualBinaryHashPolicyConfigured = hasConfiguredHashInput(hashes)
	s.rebuildBinaryHashPolicyLocked()
}

func normalizeKnownBinaryHashes(hashes []string, logger *slog.Logger) map[string]bool {
	normalizedHashes := make(map[string]bool, len(hashes))
	for _, h := range hashes {
		normalized, err := normalizeSHA256Hex(h, "known_binary_hashes")
		if err != nil {
			if strings.TrimSpace(h) != "" {
				logger.Warn("invalid known binary hash ignored", "hash", h, "error", err)
			}
			continue
		}
		normalizedHashes[normalized] = true
	}
	return normalizedHashes
}

// AddKnownBinaryHashes adds hashes to the existing known set (for env var fallback).
func (s *Server) AddKnownBinaryHashes(hashes []string) {
	normalized := normalizeKnownBinaryHashes(hashes, s.logger)

	s.binaryHashPolicyMu.Lock()
	defer s.binaryHashPolicyMu.Unlock()

	if s.manualKnownBinaryHashes == nil {
		s.manualKnownBinaryHashes = make(map[string]bool)
	}
	if hasConfiguredHashInput(hashes) {
		s.manualBinaryHashPolicyConfigured = true
	}
	for h := range normalized {
		s.manualKnownBinaryHashes[h] = true
	}
	s.rebuildBinaryHashPolicyLocked()
}

func hasConfiguredHashInput(hashes []string) bool {
	for _, h := range hashes {
		if strings.TrimSpace(h) != "" {
			return true
		}
	}
	return false
}

// SetConsoleURL sets the frontend URL for device auth verification links.
func (s *Server) SetConsoleURL(url string) {
	s.consoleURL = url
}

// SetCORSOrigin configures the allowed CORS origin.
func (s *Server) SetCORSOrigin(origin string) {
	s.corsOrigin = origin
}

// SetReleaseKey configures the scoped release key for GitHub Actions.
func (s *Server) SetReleaseKey(key string) {
	s.releaseKey = key
}

// SetCoordinatorKey installs the X25519 keypair the coordinator publishes
// for sender-to-coordinator request encryption. Pass nil to disable.
func (s *Server) SetCoordinatorKey(k *e2e.CoordinatorKey) {
	s.coordinatorKey = k
}

// CoordinatorKey returns the configured coordinator encryption key (or nil).
// Exposed for tests; production code should not need this.
func (s *Server) CoordinatorKey() *e2e.CoordinatorKey {
	return s.coordinatorKey
}

// SyncBinaryHashes rebuilds knownBinaryHashes from all active releases.
// Called at startup and after release changes.
func (s *Server) SyncBinaryHashes() {
	releases := s.store.ListReleases()
	hashes := make(map[string]bool)
	policyConfigured := false
	for _, r := range releases {
		if !r.Active {
			continue
		}
		policyConfigured = true
		normalized, err := normalizeSHA256Hex(r.BinaryHash, "release.binary_hash")
		if err != nil {
			s.logger.Warn("invalid release binary hash ignored",
				"version", r.Version,
				"platform", r.Platform,
				"error", err,
			)
			continue
		}
		hashes[normalized] = true
	}

	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = policyConfigured
	s.rebuildBinaryHashPolicyLocked()
	knownHashCount := len(s.knownBinaryHashes)
	effectivePolicyConfigured := s.binaryHashPolicyConfigured
	s.binaryHashPolicyMu.Unlock()

	s.logger.Info("binary hashes synced from releases", "known_hashes", knownHashCount, "policy_configured", effectivePolicyConfigured)
}

func (s *Server) rebuildBinaryHashPolicyLocked() {
	hashes := make(map[string]bool, len(s.manualKnownBinaryHashes)+len(s.releaseKnownBinaryHashes))
	for h := range s.releaseKnownBinaryHashes {
		hashes[h] = true
	}
	for h := range s.manualKnownBinaryHashes {
		hashes[h] = true
	}
	s.knownBinaryHashes = hashes
	s.binaryHashPolicyConfigured = s.manualBinaryHashPolicyConfigured || s.releaseBinaryHashPolicyConfigured
}

func (s *Server) binaryHashPolicySnapshot() (bool, map[string]bool) {
	s.binaryHashPolicyMu.RLock()
	defer s.binaryHashPolicyMu.RUnlock()

	return s.binaryHashPolicyConfigured, s.knownBinaryHashes
}

// SyncRuntimeManifest builds the runtime manifest from active releases.
// Called after a release is registered to auto-update the expected hashes.
func (s *Server) SyncRuntimeManifest() {
	releases := s.store.ListReleases()

	// Guard: if the store returns nil (e.g. Postgres timeout), do NOT nuke
	// a previously-good manifest. A transient DB failure should not
	// instantly deroute every provider on the network.
	if releases == nil {
		s.logger.Warn("SyncRuntimeManifest: ListReleases returned nil (DB timeout?), keeping existing manifest")
		return
	}

	// Minimum provider version is set manually via EIGENINFERENCE_MIN_PROVIDER_VERSION
	// env var. It is NOT auto-derived from the latest release — pushing a new release
	// should not instantly knock all existing providers offline.

	manifest := &RuntimeManifest{
		PythonHashes:   make(map[string]bool),
		RuntimeHashes:  make(map[string]bool),
		TemplateHashes: make(map[string]string),
	}

	// Sort releases ascending by version so newer releases' template hashes
	// overwrite older ones (templates are keyed by name; binary/runtime hashes
	// accumulate as a set).
	sortedReleases := append([]store.Release(nil), releases...)
	sort.SliceStable(sortedReleases, func(i, j int) bool {
		return semverGreater(sortedReleases[j].Version, sortedReleases[i].Version)
	})

	hasAny := false
	for _, r := range sortedReleases {
		if !r.Active {
			continue
		}
		if r.PythonHash != "" {
			manifest.PythonHashes[r.PythonHash] = true
			hasAny = true
		}
		if r.RuntimeHash != "" {
			manifest.RuntimeHashes[r.RuntimeHash] = true
			hasAny = true
		}
		if r.TemplateHashes != "" {
			// Parse "name=hash,name=hash" format
			for _, pair := range strings.Split(r.TemplateHashes, ",") {
				parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
				if len(parts) == 2 {
					manifest.TemplateHashes[parts[0]] = parts[1]
					hasAny = true
				}
			}
		}
		if r.MetallibHash != "" {
			normalized, err := normalizeSHA256Hex(r.MetallibHash, "release.metallib_hash")
			if err != nil {
				s.logger.Warn("invalid release metallib hash ignored",
					"version", r.Version,
					"platform", r.Platform,
					"error", err,
				)
			} else {
				manifest.TemplateHashes["mlx_metallib"] = normalized
				hasAny = true
			}
		}
	}

	if hasAny {
		s.knownRuntimeManifest = manifest
		s.logger.Info("runtime manifest synced from releases",
			"python_hashes", len(manifest.PythonHashes),
			"runtime_hashes", len(manifest.RuntimeHashes),
			"template_hashes", len(manifest.TemplateHashes),
		)
	} else if len(releases) > 0 {
		// Explicit empty: releases exist but none have hashes. Clear manifest.
		s.knownRuntimeManifest = nil
		s.logger.Info("runtime manifest cleared: releases exist but none have runtime hashes")
	} else {
		// Empty releases slice (not nil — nil is handled above). No releases
		// at all, which is only expected on a fresh coordinator. Keep
		// existing manifest if one exists.
		if s.knownRuntimeManifest != nil {
			s.logger.Warn("SyncRuntimeManifest: zero releases returned, keeping existing manifest")
			return
		}
		s.knownRuntimeManifest = nil
	}

	s.revalidateConnectedProvidersAgainstRuntimePolicy()
}

func (s *Server) revalidateConnectedProvidersAgainstRuntimePolicy() {
	// Note: the DB-timeout case (ListReleases returns nil) is already guarded
	// in SyncRuntimeManifest — it returns early before reaching this function.
	// A nil manifest here means releases exist but none carry runtime hashes,
	// i.e. an intentional manifest withdrawal. Providers must be derouted.

	for _, providerID := range s.registry.ProviderIDs() {
		provider := s.registry.GetProvider(providerID)
		if provider == nil {
			continue
		}

		provider.Mu().Lock()
		pythonHash := provider.PythonHash
		runtimeHash := provider.RuntimeHash
		templateHashes := registry.CloneStringMap(provider.TemplateHashes)
		version := provider.Version
		backend := provider.Backend

		if s.knownRuntimeManifest == nil {
			// Manifest was withdrawn — deroute provider until the next
			// successful challenge re-verifies it.
			provider.RuntimeVerified = false
			provider.RuntimeManifestChecked = false
		} else if s.minProviderVersion != "" &&
			version != "" &&
			semverLess(version, s.minProviderVersion) {
			provider.RuntimeVerified = false
			provider.RuntimeManifestChecked = false
			s.ddIncr("provider_version_below_minimum", []string{"gate:manifest_sync", "version:" + version})
		} else {
			runtimeOK, _ := s.verifyRuntimeHashesForBackend(
				backend,
				pythonHash,
				runtimeHash,
				templateHashes,
			)
			if !runtimeOK {
				provider.RuntimeVerified = false
				provider.RuntimeManifestChecked = false
			}
		}
		provider.Mu().Unlock()
	}
}

// RuntimeManifest holds the set of accepted hashes for provider runtime components.
// When configured, the coordinator verifies provider-reported hashes against
// this manifest at registration and during periodic attestation challenges.
type RuntimeManifest struct {
	PythonHashes   map[string]bool   `json:"python_hashes"`   // set of accepted Python runtime hashes
	RuntimeHashes  map[string]bool   `json:"runtime_hashes"`  // set of accepted inference runtime hashes
	TemplateHashes map[string]string `json:"template_hashes"` // template_name -> expected hash
}

// SetRuntimeManifest configures the known-good runtime manifest for provider
// verification. Pass nil to disable runtime verification (all providers pass).
// semverGreater returns true if version a is greater than version b.
// Compares numeric components (e.g. "0.2.31" > "0.2.9" = true).
func semverGreater(a, b string) bool {
	if a == "" {
		return false
	}
	if b == "" {
		return true
	}
	aParts := strings.Split(a, ".")
	bParts := strings.Split(b, ".")
	for i := 0; i < len(aParts) || i < len(bParts); i++ {
		var ai, bi int
		if i < len(aParts) {
			fmt.Sscanf(aParts[i], "%d", &ai)
		}
		if i < len(bParts) {
			fmt.Sscanf(bParts[i], "%d", &bi)
		}
		if ai > bi {
			return true
		}
		if ai < bi {
			return false
		}
	}
	return false // equal
}

// semverLess returns true if version a is less than version b.
func semverLess(a, b string) bool {
	return semverGreater(b, a)
}

func (s *Server) SetRuntimeManifest(m *RuntimeManifest) {
	s.knownRuntimeManifest = m
}

func (s *Server) verifyRuntimeHashesForBackend(backend, pythonHash, runtimeHash string, templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	if s.knownRuntimeManifest == nil {
		return true, nil
	}

	// Only mlx-swift backends are supported. Non-Swift backends (legacy
	// Python/inprocess-mlx) are deprecated and immediately rejected.
	if !registry.BackendUsesSwiftRuntime(backend) {
		return false, []protocol.RuntimeMismatch{{
			Component: "backend",
			Expected:  "mlx-swift",
			Got:       backend,
		}}
	}

	manifest := s.knownRuntimeManifest
	scoped := &RuntimeManifest{
		PythonHashes:   map[string]bool{},
		RuntimeHashes:  map[string]bool{},
		TemplateHashes: map[string]string{},
	}
	scopedReportedTemplates := make(map[string]string)

	if expected := manifest.TemplateHashes["mlx_metallib"]; expected != "" {
		scoped.TemplateHashes["mlx_metallib"] = expected
	}
	if got := templateHashes["mlx_metallib"]; got != "" {
		scopedReportedTemplates["mlx_metallib"] = got
	}

	return s.verifyRuntimeHashesAgainstManifest(scoped, pythonHash, runtimeHash, scopedReportedTemplates)
}

func (s *Server) verifyRuntimeHashesAgainstManifest(manifest *RuntimeManifest, pythonHash, runtimeHash string, templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	if manifest == nil {
		return true, nil
	}

	var mismatches []protocol.RuntimeMismatch

	requireOneOf := func(component, got string, accepted map[string]bool) {
		if len(accepted) == 0 {
			return
		}
		if got == "" {
			mismatches = append(mismatches, protocol.RuntimeMismatch{
				Component: component,
				Expected:  "reported hash matching one of known-good values",
				Got:       "(missing)",
			})
			return
		}
		if !accepted[got] {
			mismatches = append(mismatches, protocol.RuntimeMismatch{
				Component: component,
				Expected:  "one of known-good hashes",
				Got:       got,
			})
		}
	}

	requireOneOf("python", pythonHash, manifest.PythonHashes)
	requireOneOf("runtime", runtimeHash, manifest.RuntimeHashes)

	if len(manifest.TemplateHashes) > 0 {
		for name, expected := range manifest.TemplateHashes {
			got, ok := templateHashes[name]
			if !ok || got == "" {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       "(missing)",
				})
				continue
			}
			if got != expected {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       got,
				})
			}
		}
		for name, got := range templateHashes {
			if _, ok := manifest.TemplateHashes[name]; !ok {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  "template listed in runtime manifest",
					Got:       got,
				})
			}
		}
	}

	return len(mismatches) == 0, mismatches
}

// handleRuntimeManifest returns the current runtime manifest as JSON.
// No auth required — hashes are not secrets.
func (s *Server) handleRuntimeManifest(w http.ResponseWriter, r *http.Request) {
	const cacheKey = "runtime_manifest:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}
	var resp map[string]any
	if s.knownRuntimeManifest == nil {
		resp = map[string]any{"configured": false}
	} else {
		resp = map[string]any{
			"configured":      true,
			"python_hashes":   s.knownRuntimeManifest.PythonHashes,
			"runtime_hashes":  s.knownRuntimeManifest.RuntimeHashes,
			"template_hashes": s.knownRuntimeManifest.TemplateHashes,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode manifest"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}

// maxMDMWebhookBodyBytes caps the MicroMDM webhook body. SecurityInfo /
// DevicePropertiesAttestation responses are a few KB; 1 MiB is generous headroom
// while preventing an unauthenticated caller from exhausting memory via an
// unbounded body.
const maxMDMWebhookBodyBytes = 1 << 20 // 1 MiB

// HandleMDMWebhook processes a MicroMDM webhook callback.
// Mount this on the webhook URL configured in MicroMDM.
//
// Defense layers (the endpoint is reachable but cannot forge trust):
//  1. Body cap — bounds memory for the unauthenticated path.
//  2. Optional shared secret — when configured, rejects callers without it
//     before reading the body.
//  3. Solicited-command gate (in mdm.Client.HandleWebhook) — only responses
//     whose CommandUUID matches a command the coordinator actually issued are
//     acted on, so a forged SecurityInfo can never drive a trust upgrade.
func (s *Server) HandleMDMWebhook(w http.ResponseWriter, r *http.Request) {
	if s.mdmWebhookSecret != "" && !s.mdmWebhookTokenValid(r) {
		s.logger.Warn("mdm webhook rejected: missing/invalid shared secret", "remote_addr", r.RemoteAddr)
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxMDMWebhookBodyBytes)
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	s.logger.Debug("mdm webhook received", "body_size", len(body), "body_preview", string(body[:min(len(body), 500)]))
	if s.mdmClient != nil {
		s.mdmClient.HandleWebhook(body)
	}
	w.WriteHeader(http.StatusOK)
}

// mdmWebhookTokenValid reports whether the request carries the configured MDM
// webhook secret, via either the X-Webhook-Token header or a ?token= query
// param. Comparison is constant-time. Only called when a secret is configured.
func (s *Server) mdmWebhookTokenValid(r *http.Request) bool {
	token := r.Header.Get("X-Webhook-Token")
	if token == "" {
		token = r.URL.Query().Get("token")
	}
	return token != "" &&
		subtle.ConstantTimeCompare([]byte(token), []byte(s.mdmWebhookSecret)) == 1
}

//go:embed install.sh
var installScript []byte

// installScriptPlaceholder is substituted with the coordinator's public URL at
// serve time. Keep in sync with coordinator/internal/api/install.sh.
//
// The legacy install.sh also substituted __DARKBLOOM_R2_CDN_URL__ and
// __DARKBLOOM_R2_SITE_PACKAGES_CDN_URL__ for the Python runtime download.
// Post-Swift-cutover (v0.5.0+) install.sh no longer touches R2 directly --
// model downloads run inside `darkbloom models download` against the public
// R2 CDN -- so only the coordinator URL needs serve-time templating.
const installScriptPlaceholder = "__DARKBLOOM_COORD_URL__"

// resolveBaseURL returns the configured baseURL, or derives one from the
// request's Host header when baseURL is unset. TLS-terminating proxies pass
// through the original scheme via X-Forwarded-Proto; default to https.
func (s *Server) resolveBaseURL(r *http.Request) string {
	if s.baseURL != "" {
		return s.baseURL
	}
	scheme := "https"
	if proto := r.Header.Get("X-Forwarded-Proto"); proto != "" {
		scheme = proto
	} else if r.TLS == nil {
		scheme = "http"
	}
	return scheme + "://" + r.Host
}

// routes mounts all HTTP and WebSocket handlers.
func (s *Server) routes() {
	// Install script — served from embedded binary with coordinator URL +
	// R2 CDN URLs substituted per environment.
	s.mux.HandleFunc("GET /install.sh", func(w http.ResponseWriter, r *http.Request) {
		rendered := strings.ReplaceAll(string(installScript), installScriptPlaceholder, s.resolveBaseURL(r))
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		io.WriteString(w, rendered)
	})

	// Health check — no auth required.
	s.mux.HandleFunc("GET /health", s.handleHealth)

	// Provider WebSocket — no API key auth (providers authenticate differently).
	s.mux.HandleFunc("GET /ws/provider", s.handleProviderWS)

	// Key management — requires interactive Privy session (API keys rejected
	// to prevent self-replication from a leaked key).
	s.mux.HandleFunc("POST /v1/auth/keys", s.requirePrivyAuth(s.rateLimitFinancial(s.handleCreateKey)))
	s.mux.HandleFunc("DELETE /v1/auth/keys", s.requirePrivyAuth(s.handleRevokeKey))

	// Multi-key management (OpenRouter-shaped CRUD). One account may own many
	// named, individually-limited keys. Management requires an interactive
	// Privy session so a leaked inference key can't enumerate or mint keys.
	s.mux.HandleFunc("GET /v1/keys", s.requirePrivyAuth(s.handleListAPIKeys))
	s.mux.HandleFunc("POST /v1/keys", s.requirePrivyAuth(s.rateLimitFinancial(s.handleCreateAPIKey)))
	s.mux.HandleFunc("GET /v1/keys/{id}", s.requirePrivyAuth(s.handleGetAPIKey))
	s.mux.HandleFunc("PATCH /v1/keys/{id}", s.requirePrivyAuth(s.rateLimitFinancial(s.handleUpdateAPIKey)))
	s.mux.HandleFunc("DELETE /v1/keys/{id}", s.requirePrivyAuth(s.rateLimitFinancial(s.handleDeleteAPIKey)))
	s.mux.HandleFunc("POST /v1/keys/{id}/rotate", s.requirePrivyAuth(s.rateLimitFinancial(s.handleRotateAPIKey)))
	// Metadata for the calling key (OpenRouter parity) — API key auth.
	s.mux.HandleFunc("GET /v1/key", s.requireAuth(s.handleGetCallingKey))

	// Consumer endpoints — API key auth required + per-account rate limit.
	// Inference endpoints are wrapped in sealedTransport so senders can opt into
	// sender→coordinator encryption by setting Content-Type:
	// application/eigeninference-sealed+json (see sender_encryption.go).
	// rateLimitConsumer is chained inside requireAuth so the accountID is in
	// context. Read-only endpoints (GET /v1/models) skip rate limiting since
	// they're cheap and clients poll them.
	s.mux.HandleFunc("POST /v1/chat/completions", s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleChatCompletions))))
	s.mux.HandleFunc("POST /v1/responses", s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleChatCompletions)))) // Responses API — same handler, auto-detects input vs messages
	s.mux.HandleFunc("POST /v1/completions", s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleCompletions))))
	s.mux.HandleFunc("POST /v1/messages", s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleAnthropicMessages))))
	s.mux.HandleFunc("GET /v1/models", s.requireAuth(s.handleListModels))
	// Dedicated OpenRouter provider feed — pure OpenRouter schema, no Darkbloom metadata.
	s.mux.HandleFunc("GET /v1/models/openrouter", s.requireAuth(s.handleListModelsOpenRouter))

	// Sender encryption — public key publication for sender→coordinator E2E.
	// Optional: senders may use this to encrypt request bodies; plaintext path
	// continues to work unchanged when this header isn't set.
	s.mux.HandleFunc("GET /v1/encryption-key", s.handleEncryptionKey)

	// MDM webhook — MicroMDM sends command responses here.
	s.mux.HandleFunc("POST /v1/mdm/webhook", s.HandleMDMWebhook)

	// Payment endpoints — API key auth required.
	s.mux.HandleFunc("GET /v1/payments/balance", s.requireAuth(s.handleBalance))
	s.mux.HandleFunc("GET /v1/payments/usage", s.requireAuth(s.handleUsage))

	// Provider earnings — no API key auth (providers identify by provider address).
	s.mux.HandleFunc("GET /v1/provider/earnings", s.handleProviderEarnings)

	// Per-node provider earnings — public by provider_key, or auth'd by account.
	s.mux.HandleFunc("GET /v1/provider/node-earnings", s.handleNodeEarnings)
	s.mux.HandleFunc("GET /v1/provider/account-earnings", s.requireAuth(s.handleAccountEarnings))

	// Account-scoped provider dashboard.
	s.mux.HandleFunc("GET /v1/me/providers", s.requirePrivyAuth(s.handleMyProviders))
	s.mux.HandleFunc("GET /v1/me/summary", s.requirePrivyAuth(s.handleMySummary))

	// ACME enrollment — generates per-device .mobileconfig for device-attest-01.
	// No auth needed — security comes from Apple's attestation during ACME challenge.
	s.mux.HandleFunc("POST /v1/enroll", s.handleEnroll)

	// Attestation verification — public, no auth needed.
	// Users can independently verify Apple's MDA certificate chain.
	s.mux.HandleFunc("GET /v1/providers/attestation", s.handleProviderAttestation)

	// Capacity snapshot — no auth needed. Upstream routers poll this.
	s.mux.HandleFunc("GET /v1/models/capacity", s.handleModelsCapacity)

	// Platform stats — no auth needed. Frontend dashboard uses this.
	s.mux.HandleFunc("GET /v1/stats", s.handleStats)

	// Public leaderboard + network totals — no auth, pseudonymized,
	// 5-min/1-min cache.
	s.mux.HandleFunc("GET /v1/leaderboard", s.handleLeaderboard)
	s.mux.HandleFunc("GET /v1/network/totals", s.handleNetworkTotals)

	// Provider version check — no auth needed. Providers call this to check for updates.
	s.mux.HandleFunc("GET /api/version", s.handleVersion)

	// Releases — versioned provider binary distribution.
	s.mux.HandleFunc("POST /v1/releases", s.handleRegisterRelease)     // scoped release key (GitHub Action)
	s.mux.HandleFunc("GET /v1/releases/latest", s.handleLatestRelease) // public (install.sh)

	// Device authorization flow — providers link to user accounts.
	s.mux.HandleFunc("POST /v1/device/code", s.handleDeviceCode)   // no auth — provider not yet authenticated
	s.mux.HandleFunc("POST /v1/device/token", s.handleDeviceToken) // no auth — polls with device_code secret
	// Device approve issues a long-lived provider→account linking token —
	// same risk class as /v1/auth/keys, so financial-tier limit applies.
	// Uses requirePrivyAuth to reject API keys (interactive session only).
	s.mux.HandleFunc("POST /v1/device/approve", s.requirePrivyAuth(s.rateLimitFinancial(s.handleDeviceApprove)))

	// --- Billing endpoints (Stripe payments + referrals) ---

	// Stripe — financial limiter on session creation (creates a checkout
	// intent, hits external API). Read-only status endpoint not throttled.
	s.mux.HandleFunc("POST /v1/billing/stripe/create-session", s.requireAuth(s.rateLimitFinancial(s.handleStripeCreateSession)))
	s.mux.HandleFunc("POST /v1/billing/stripe/webhook", s.handleStripeWebhook) // no auth — Stripe signs it
	s.mux.HandleFunc("GET /v1/billing/stripe/session", s.requireAuth(s.handleStripeSessionStatus))

	// Wallet balance
	s.mux.HandleFunc("GET /v1/billing/wallet/balance", s.requireAuth(s.handleWalletBalance))

	// Stripe Payouts (Connect Express) — bank/card withdrawals.
	s.mux.HandleFunc("POST /v1/billing/stripe/onboard", s.requireAuth(s.handleStripeOnboard))
	s.mux.HandleFunc("GET /v1/billing/stripe/status", s.requireAuth(s.handleStripeStatus))
	s.mux.HandleFunc("POST /v1/billing/withdraw/stripe", s.requireAuth(s.handleStripeWithdraw))
	s.mux.HandleFunc("GET /v1/billing/stripe/withdrawals", s.requireAuth(s.handleStripeWithdrawals))
	s.mux.HandleFunc("POST /v1/billing/stripe/connect/webhook", s.handleStripeConnectWebhook) // no auth — Stripe signs it

	// Pricing — GET is public, PUT/DELETE require auth
	s.mux.HandleFunc("GET /v1/pricing", s.handleGetPricing)                        // public
	s.mux.HandleFunc("PUT /v1/pricing", s.requireAuth(s.handleSetPricing))         // provider sets own prices
	s.mux.HandleFunc("DELETE /v1/pricing", s.requireAuth(s.handleDeletePricing))   // revert to default
	s.mux.HandleFunc("PUT /v1/admin/pricing", s.requireAuth(s.handleAdminPricing)) // platform sets defaults

	// Admin account management (service-role + per-account platform fee)
	s.mux.HandleFunc("PUT /v1/admin/users/role", s.requireAuth(s.handleAdminSetUserRole))
	s.mux.HandleFunc("PUT /v1/admin/users/platform-fee", s.requireAuth(s.handleAdminSetUserPlatformFee))

	// Admin model registry (manifest-backed). The legacy supported_models CRUD
	// (bare GET/POST/DELETE /v1/admin/models) was removed; the model_registry is
	// the single source of truth. Use register + the per-model action endpoints.
	s.mux.HandleFunc("POST /v1/admin/models/register", s.handleRegisterModel)
	// Public model aliases (stable names → concrete builds). More-specific
	// patterns take precedence over the POST /v1/admin/models/ subtree below.
	s.mux.HandleFunc("GET /v1/admin/models/aliases", s.handleModelAliasList)
	s.mux.HandleFunc("POST /v1/admin/models/aliases", s.handleModelAliasUpsert)
	s.mux.HandleFunc("DELETE /v1/admin/models/aliases/{aliasID}", s.handleModelAliasDelete)
	s.mux.HandleFunc("POST /v1/admin/models/", s.handleAdminModelRegistryAction)
	s.mux.HandleFunc("GET /v1/admin/releases", s.handleAdminListReleases)     // admin key or Privy admin
	s.mux.HandleFunc("DELETE /v1/admin/releases", s.handleAdminDeleteRelease) // admin key or Privy admin

	// Admin state export (DAR-70) — streams the TEE-sealed /data archive
	// (step-ca + MicroMDM) for migration off EigenCloud. Always registered, but
	// inert (404) unless EIGENINFERENCE_STATE_EXPORT_ENABLED=true; admin-gated;
	// encrypted to an age recipient by default. Auth + output protection are
	// enforced inside the handler.
	s.mux.HandleFunc("GET /v1/admin/state-export", s.handleAdminStateExport)

	// Admin CLI auth — Privy email OTP for getting admin tokens without a browser.
	s.mux.HandleFunc("POST /v1/admin/auth/init", s.handleAdminAuthInit)     // no auth (sends OTP)
	s.mux.HandleFunc("POST /v1/admin/auth/verify", s.handleAdminAuthVerify) // no auth (returns token)

	// Public model catalog — providers and install script fetch this
	s.mux.HandleFunc("GET /v1/models/catalog", s.handleModelCatalog)
	s.mux.HandleFunc("GET /v1/models/catalog/manifest/", s.handleModelCatalogManifest)
	s.mux.HandleFunc("GET /v1/models/catalog/", s.handleModelCatalogItem)

	// Runtime manifest — providers and users can inspect accepted runtime hashes.
	s.mux.HandleFunc("GET /v1/runtime/manifest", s.handleRuntimeManifest)

	// Payment methods info
	s.mux.HandleFunc("GET /v1/billing/methods", s.handleBillingMethods) // no auth needed

	// Referral system — register/apply mutate referral graph (financial
	// limiter); stats/info are read-only.
	s.mux.HandleFunc("POST /v1/referral/register", s.requireAuth(s.rateLimitFinancial(s.handleReferralRegister)))
	s.mux.HandleFunc("POST /v1/referral/apply", s.requireAuth(s.rateLimitFinancial(s.handleReferralApply)))
	s.mux.HandleFunc("GET /v1/referral/stats", s.requireAuth(s.handleReferralStats))
	s.mux.HandleFunc("GET /v1/referral/info", s.requireAuth(s.handleReferralInfo))

	// Invite codes (admin)
	// Invite code creation accepts amount_usd and produces a credit-bearing
	// code; redemption is already financial-tier so the issuance side must
	// match (otherwise an admin-key holder could spam codes anyway, but
	// keeping symmetry).
	s.mux.HandleFunc("POST /v1/admin/invite-codes", s.requireAuth(s.rateLimitFinancial(s.handleAdminCreateInviteCode)))
	s.mux.HandleFunc("GET /v1/admin/invite-codes", s.requireAuth(s.handleAdminListInviteCodes))
	s.mux.HandleFunc("DELETE /v1/admin/invite-codes", s.requireAuth(s.handleAdminDeactivateInviteCode))

	// Invite code redemption (user) — credits the redeemer's balance, so
	// it's a financial-tier endpoint.
	s.mux.HandleFunc("POST /v1/invite/redeem", s.requireAuth(s.rateLimitFinancial(s.handleRedeemInviteCode)))

	// Admin credit & reward
	s.mux.HandleFunc("POST /v1/admin/credit", s.requireAuth(s.handleAdminCredit))
	s.mux.HandleFunc("POST /v1/admin/reward", s.requireAuth(s.handleAdminReward))

	// Telemetry ingestion — authentication is resolved inside the handler
	// because providers, consumers, and anonymous clients all hit this path.
	// Events are forwarded to Datadog; admin read/summary endpoints have been
	// removed (use Datadog Log Explorer).
	s.mux.HandleFunc("POST /v1/telemetry/events", s.handleTelemetryIngest)

	// Provider log reports
	s.mux.HandleFunc("POST /v1/provider/log-report", s.requireAuth(s.handleUploadLogReport))
	s.mux.HandleFunc("GET /v1/admin/log-reports", s.requireAuth(s.handleListLogReports))
	s.mux.HandleFunc("GET /v1/admin/log-reports/{id}", s.requireAuth(s.handleGetLogReport))

	// Metrics snapshot (admin only)
	s.mux.HandleFunc("GET /v1/admin/metrics", s.handleAdminMetrics)

	// Catch-all for unimplemented OpenAI-compatible endpoints.
	// Registered last (old-style pattern) so explicit method+path routes
	// take precedence. Any /v1/* path not handled above gets a structured
	// JSON error instead of the mux default text/plain 404.
	s.mux.HandleFunc("/v1/", s.handleUnimplementedEndpoint)
}

// registerDefaultGauges wires live-computed gauges (fleet size, etc.) into
// the metrics registry at construction time.
func (s *Server) registerDefaultGauges() {
	s.metrics.RegisterGauge("providers_online", func() float64 {
		return float64(s.registry.ProviderCount())
	})
	s.metrics.RegisterGauge("min_provider_version_set", func() float64 {
		if s.minProviderVersion != "" {
			return 1
		}
		return 0
	})
}

// StartDDGaugeLoop periodically pushes gauge values to DogStatsD. Gauges
// are point-in-time values and must be pushed regularly (not on-demand like
// counters). Call as a goroutine; stops when ctx is cancelled.
func (s *Server) StartDDGaugeLoop(ctx context.Context) {
	if s.dd == nil {
		return
	}
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.ddGauge("providers.online", float64(s.registry.OnlineCount()), nil)
			// APNs code-identity coverage — watch this climb during the grace
			// window before letting APNS_ENFORCE_AFTER pass.
			codeAttested, _ := s.registry.CodeAttestationCoverage()
			s.ddGauge("attestation.code_attested", float64(codeAttested), nil)
			enforced := 0.0
			if s.registry.CodeAttestationEnforced() {
				enforced = 1.0
			}
			s.ddGauge("attestation.code_enforced", enforced, nil)
			for model, count := range s.registry.ModelProviderSnapshot() {
				s.ddGauge("providers.per_model", float64(count), []string{"model:" + model})
			}
			for ver, count := range s.registry.ProviderCountByVersion() {
				s.ddGauge("providers.per_version", float64(count), []string{"version:" + ver})
			}
			if s.minProviderVersion != "" {
				s.ddGauge("coordinator.min_provider_version_set", 1, []string{"min_version:" + s.minProviderVersion})
			}
			if q := s.registry.Queue(); q != nil {
				s.ddGauge("request_queue.depth", float64(q.TotalSize()), nil)
			}
		}
	}
}

// handleAdminMetrics returns the metrics snapshot in JSON or Prometheus text.
func (s *Server) handleAdminMetrics(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	snap := s.metrics.Snapshot()
	if r.URL.Query().Get("format") == "prom" {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(snap.RenderProm()))
		return
	}
	writeJSON(w, http.StatusOK, snap)
}

// handleUnimplementedEndpoint returns a structured JSON error for any /v1/*
// path not registered as an explicit route. This prevents OpenAI SDK clients
// from crashing on raw text/plain 404s when hitting unimplemented endpoints
// like /v1/embeddings or /v1/moderations.
func (s *Server) handleUnimplementedEndpoint(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotFound, errorResponse(
		"invalid_request_error",
		fmt.Sprintf("endpoint %s %s is not implemented", r.Method, r.URL.Path),
	))
}

// Handler returns the root http.Handler with global middleware applied.
// Middleware order (outside-in):
//
//	cors → recover → logging → mux
//
// Recover must sit outside logging so a panic during logging doesn't leak.
func (s *Server) Handler() http.Handler {
	return s.corsMiddleware(s.recoverMiddleware(s.loggingMiddleware(s.mux)))
}

// recoverMiddleware catches panics in any handler, emits a telemetry event
// with the stack trace, and returns 500 to the client. Without this, a single
// nil deref takes down the whole coordinator — panics from tests have hit us
// in production more than once.
func (s *Server) recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				if recErr, ok := rec.(error); ok && errors.Is(recErr, http.ErrAbortHandler) {
					panic(rec)
				}
				stack := string(debug.Stack())
				s.logger.Error("panic in HTTP handler",
					"error", fmt.Sprintf("%v", rec),
					"path", r.URL.Path,
					"method", r.Method,
					"stack", stack,
				)
				s.emitPanic(r.Context(),
					fmt.Sprintf("panic in handler %s %s: %v", r.Method, r.URL.Path, rec),
					stack,
					map[string]any{
						"handler":  r.URL.Path,
						"endpoint": r.URL.Path,
					},
				)
				// Write a 500 if the response hasn't started yet. If the
				// handler already flushed headers (e.g. streaming SSE), we
				// can't do anything useful — the client will see the stream
				// truncated.
				defer func() { _ = recover() }() // guard against double-write
				writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "internal server error"))
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// lookupAPIKeyCache returns a cached ValidateKeyFull result if present and
// not expired. Returns false on miss or expiry.
func (s *Server) lookupAPIKeyCache(token string) (apiKeyCacheEntry, bool) {
	s.apiKeyCacheMu.RLock()
	entry, ok := s.apiKeyCache[token]
	gen := s.apiKeyCacheGen
	s.apiKeyCacheMu.RUnlock()
	// Miss on absence, TTL expiry, or a stale generation (a key mutation has
	// occurred since the entry was cached).
	if !ok || entry.gen != gen || time.Since(entry.cachedAt) > apiKeyCacheTTL {
		return apiKeyCacheEntry{}, false
	}
	return entry, true
}

// storeAPIKeyCache inserts an auth result into the cache, stamped with the
// current generation. If the cache is at capacity, the oldest entry is evicted.
func (s *Server) storeAPIKeyCache(token string, entry apiKeyCacheEntry) {
	s.apiKeyCacheMu.Lock()
	defer s.apiKeyCacheMu.Unlock()
	entry.gen = s.apiKeyCacheGen
	if len(s.apiKeyCache) >= apiKeyCacheMaxSize {
		var oldest string
		var oldestTime time.Time
		for k, v := range s.apiKeyCache {
			if oldest == "" || v.cachedAt.Before(oldestTime) {
				oldest = k
				oldestTime = v.cachedAt
			}
		}
		delete(s.apiKeyCache, oldest)
	}
	s.apiKeyCache[token] = entry
}

// invalidateAPIKeyCache removes a single key from the API key cache. Called
// when a key is revoked so stale positive results don't grant access.
func (s *Server) invalidateAPIKeyCache(token string) {
	s.apiKeyCacheMu.Lock()
	delete(s.apiKeyCache, token)
	s.apiKeyCacheMu.Unlock()
}

// invalidateAllAPIKeyCache atomically invalidates every cached auth result by
// bumping the cache generation (entries cached under an older generation are
// ignored). Called BEFORE and AFTER a by-ID key mutation (update/revoke/rotate)
// where we don't hold the raw token: the pre-bump drops any pre-existing entry,
// and the post-bump drops any entry a concurrent request re-cached from
// pre-commit state during the mutation — closing the read-stale race.
func (s *Server) invalidateAllAPIKeyCache() {
	s.apiKeyCacheMu.Lock()
	s.apiKeyCacheGen++
	s.apiKeyCache = make(map[string]apiKeyCacheEntry)
	s.apiKeyCacheMu.Unlock()
}

// requireAuth wraps a handler with authentication. It tries Privy JWT first
// (if configured), then falls back to API key validation. The authenticated
// identity is stored in the request context for downstream use.
func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := extractBearerToken(r)
		if token == "" {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "missing credentials — use Authorization: Bearer <token>"))
			return
		}

		// Try Privy JWT first (JWTs start with "eyJ").
		if s.privyAuth != nil && strings.HasPrefix(token, "eyJ") {
			privyUserID, err := s.privyAuth.VerifyToken(token)
			if err != nil {
				writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid Privy token"))
				return
			}
			user, err := s.privyAuth.GetOrCreateUser(privyUserID)
			if err != nil {
				s.logger.Error("privy: user resolution failed", "error", err)
				writeJSON(w, http.StatusInternalServerError, errorResponse("auth_error", "failed to resolve user"))
				return
			}
			ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
			ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			next(w, r.WithContext(ctx))
			return
		}

		// Accept admin key (admin endpoints handle further authorization in-handler).
		if s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
			ctx := context.WithValue(r.Context(), ctxKeyConsumer, "admin")
			next(w, r.WithContext(ctx))
			return
		}

		// Fall back to API key auth.
		// Check cache first to skip DB on repeat requests with the same key.
		var keyRec *store.APIKey
		if cached, ok := s.lookupAPIKeyCache(token); ok {
			keyRec = cached.key
		} else {
			// Cache miss — resolve the key (with its per-key limits) in one
			// query. A disabled/expired/unknown key returns an error and falls
			// through to the provider-token path below.
			if k, err := s.store.AuthenticateKey(token); err == nil {
				keyRec = k
				// Throttled last-used update: cache misses happen at most once
				// per TTL per active key, so this naturally rate-limits writes.
				if k.ID != "" {
					id := k.ID
					saferun.Go(s.logger, "touch_api_key", func() {
						s.store.TouchAPIKey(id, time.Now())
					})
				}
				// Unlinked legacy key: its identity used to be the raw bearer
				// token; it is now LegacyAccountID(token). Carry any balance from
				// the old raw-token identity to the new one so a pre-existing
				// funded legacy key doesn't suddenly read a zero balance. One-time
				// and a no-op once moved; runs only on a cache miss (≈ once per
				// TTL). The raw token is never logged.
				if k.OwnerAccountID == "" {
					if _, err := s.store.MigrateAccountBalance(token, store.LegacyAccountID(token)); err != nil {
						s.logger.Warn("legacy key balance migration failed", "error", err)
					}
				}
				// Cache the API-key result (positive or negative). Provider-token
				// fallbacks are deliberately NOT cached below.
				s.storeAPIKeyCache(token, apiKeyCacheEntry{key: keyRec, cachedAt: time.Now()})
			} else if pt, err := s.store.GetProviderToken(token); err == nil && pt != nil && pt.Active {
				// Provider device-login tokens authenticate as an account-scoped
				// identity with no per-key limits (ID left empty). These are NOT
				// cached: provider-token revocation has no api-key-cache
				// invalidation hook, so caching would let a revoked token live
				// until TTL. GetProviderToken is cheap and provider-token traffic
				// is low-volume.
				keyRec = &store.APIKey{OwnerAccountID: pt.AccountID}
			} else {
				// Unknown token — negative-cache to avoid hammering the DB.
				s.storeAPIKeyCache(token, apiKeyCacheEntry{key: nil, cachedAt: time.Now()})
			}
		}

		// Re-check time-based expiry / disable on the cache-hit path: a key can
		// expire while a positive entry is still within its TTL, and no mutation
		// event clears the cache on a time-based expiry.
		if keyRec != nil && (keyRec.Disabled || (keyRec.ExpiresAt != nil && time.Now().After(*keyRec.ExpiresAt))) {
			keyRec = nil
		}

		if keyRec == nil {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid API key"))
			return
		}

		// Resolve key → account. If the key is linked to a Privy account, use
		// that account ID and load the user. Unlinked legacy keys derive a
		// stable, non-secret identity (legacy:<sha256>) instead of using the raw
		// bearer token, so the secret never reaches balances.account_id, ledger
		// references, or logs.
		accountID := keyRec.OwnerAccountID
		ctx := r.Context()
		if accountID != "" {
			if user, err := s.store.GetUserByAccountID(accountID); err == nil {
				ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			}
		} else {
			accountID = store.LegacyAccountID(token)
		}

		ctx = context.WithValue(ctx, ctxKeyConsumer, accountID)
		ctx = context.WithValue(ctx, ctxKeyAPIKey, keyRec)
		next(w, r.WithContext(ctx))
	}
}

// requirePrivyAuth wraps a handler requiring a Privy JWT session. Unlike
// requireAuth, API keys are rejected. Use for sensitive account operations
// (key creation, device approval) that must not be triggerable by a leaked
// API key.
func (s *Server) requirePrivyAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := extractBearerToken(r)
		if token == "" {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "missing credentials"))
			return
		}
		if s.privyAuth == nil || !strings.HasPrefix(token, "eyJ") {
			writeJSON(w, http.StatusForbidden, errorResponse("forbidden",
				"this endpoint requires an interactive session — API keys are not accepted"))
			return
		}
		privyUserID, err := s.privyAuth.VerifyToken(token)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "invalid Privy token"))
			return
		}
		user, err := s.privyAuth.GetOrCreateUser(privyUserID)
		if err != nil {
			s.logger.Error("privy: user resolution failed", "error", err)
			writeJSON(w, http.StatusInternalServerError, errorResponse("auth_error", "failed to resolve user"))
			return
		}
		ctx := context.WithValue(r.Context(), ctxKeyConsumer, user.AccountID)
		ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
		next(w, r.WithContext(ctx))
	}
}

// rateLimitConsumer wraps a consumer-facing handler with per-account rate
// limiting. It must be chained AFTER requireAuth so the accountID is in
// the context. Admin key requests bypass the limiter (they show up as the
// "admin" pseudo-account from requireAuth — we let those through unmetered
// so admin scripts and ops tooling aren't throttled).
//
// Note: Privy users with admin emails (s.adminEmails) currently do NOT
// bypass — they receive a real accountID from requireAuth. This is
// intentional: human admins shouldn't generate enough traffic to hit
// limits, and treating them as untrusted callers preserves the invariant
// that the limiter sees one identity per real user.
//
// Returns 429 with a Retry-After header on rejection. The Retry-After
// duration is the time until at least one token replenishes, clamped to a
// sane maximum to avoid pathological values.
func (s *Server) rateLimitConsumer(next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWith(s.rateLimiterFn, next)
}

// rateLimitFinancial wraps a balance-mutating handler with the stricter
// financial-endpoint limiter. Chain inside requireAuth.
func (s *Server) rateLimitFinancial(next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWithTier(s.financialRateLimiterFn, "financial", next)
}

// The two getter methods exist so rateLimitWith can read the *current*
// limiter at request time. Routes are registered in routes() during
// NewServer, but SetRateLimiter / SetFinancialRateLimiter are called
// AFTER NewServer in main.go. Capturing the field directly at registration
// time would close over a nil pointer.
func (s *Server) rateLimiterFn() *ratelimit.Limiter          { return s.rateLimiter }
func (s *Server) financialRateLimiterFn() *ratelimit.Limiter { return s.financialRateLimiter }

func (s *Server) rateLimitWith(getLimiter func() *ratelimit.Limiter, next http.HandlerFunc) http.HandlerFunc {
	return s.rateLimitWithTier(getLimiter, "consumer", next)
}

// rateLimitWithTier is the actual implementation; callers thread a label
// for the metrics counter so we can distinguish consumer vs financial
// rejections in dashboards.
func (s *Server) rateLimitWithTier(getLimiter func() *ratelimit.Limiter, tier string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Per-key RPM override applies to inference (consumer) traffic and is
		// enforced regardless of whether the account-level limiter is set.
		if tier == "consumer" {
			if !s.applyKeyRPMLimit(w, r) {
				return
			}
		}
		rl := getLimiter()
		if rl == nil {
			next(w, r)
			return
		}
		accountID := consumerKeyFromContext(r.Context())
		if accountID == "admin" {
			next(w, r)
			return
		}
		// Service-role accounts (e.g. OpenRouter) get the elevated limiter (or
		// bypass when none is configured) — but ONLY on the consumer/inference
		// tier. Financial endpoints (deposits, withdrawals, key/invite/referral
		// mutations) keep their stricter limiter for every account, since those
		// are higher-value abuse targets regardless of role.
		if tier == "consumer" {
			if user := auth.UserFromContext(r.Context()); user != nil && user.Role == store.RoleService {
				if s.serviceRateLimiter == nil {
					next(w, r)
					return
				}
				rl = s.serviceRateLimiter
			}
		}
		if allowed, retryAfter := rl.Allow(accountID); !allowed {
			seconds := int(retryAfter.Seconds())
			if seconds < 1 {
				seconds = 1
			}
			w.Header().Set("Retry-After", strconv.Itoa(seconds))
			w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(time.Now().Add(retryAfter).Unix(), 10))
			setRequestRateLimitHeaders(w, rl.Stat(accountID))
			s.ddIncr("ratelimit.rejections", []string{"tier:" + tier})
			writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded",
				"too many requests — slow down and retry after the Retry-After interval", withCode("rate_limit_exceeded")))
			return
		}
		setRequestRateLimitHeaders(w, rl.Stat(accountID))
		next(w, r)
	}
}

// publicCORSPaths are endpoints whose GET is unauthenticated, read-only public
// data. Their GET is served with a wildcard CORS origin so the marketing site
// (darkbloom.dev) and any third party can read them from the browser. NOTE:
// some of these paths (e.g. /v1/pricing) ALSO serve authenticated PUT/DELETE —
// the wildcard applies only to GET; non-GET methods fall through to the
// credentialed, single-origin CORS below.
var publicCORSPaths = map[string]bool{
	"/v1/models/catalog": true,
	"/v1/pricing":        true,
}

// corsMiddleware sets CORS headers. Authenticated/credentialed requests are
// locked to a single origin derived from the CORS_ORIGIN environment variable
// (defaulting to the production console domain); a wildcard is never used for
// those. A GET to a public read-only endpoint (see publicCORSPaths) is readable
// from any origin, without credentials, so a wildcard is safe and intended.
func (s *Server) corsMiddleware(next http.Handler) http.Handler {
	origin := s.corsOrigin
	if origin == "" {
		origin = "https://console.darkbloom.dev"
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Resolve the effective method: for a preflight, the actual request
		// method is in Access-Control-Request-Method (default GET if absent).
		effectiveMethod := r.Method
		if r.Method == http.MethodOptions {
			if reqMethod := r.Header.Get("Access-Control-Request-Method"); reqMethod != "" {
				effectiveMethod = reqMethod
			} else {
				effectiveMethod = http.MethodGet
			}
		}

		if publicCORSPaths[r.URL.Path] && effectiveMethod == http.MethodGet {
			// Public, non-credentialed GET — any origin may read it.
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
			w.Header().Set("Vary", "Origin")
		} else {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			w.Header().Set("Access-Control-Allow-Credentials", "true")
		}

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// loggingMiddleware logs each request using slog and updates HTTP metrics.
func (s *Server) loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}

		// Generate (or honor) a request_id and stash it in context +
		// response headers so logs and the client can correlate.
		reqID := r.Header.Get("X-Request-ID")
		if reqID == "" {
			reqID = newRequestID()
		}
		w.Header().Set("X-Request-ID", reqID)
		ctx := context.WithValue(r.Context(), ctxKeyRequestID, reqID)
		r = r.WithContext(ctx)

		next.ServeHTTP(sw, r)

		dur := time.Since(start)

		// Resolve the route pattern that matched (Go 1.22+ method+path).
		// Falls back to URL.Path when no pattern matched (404).
		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}

		// User correlation: if requireAuth attached an account, include
		// it in the access log. Empty for unauthenticated paths.
		userID := consumerKeyFromContext(ctx)

		s.logger.Info("request",
			"request_id", reqID,
			"method", r.Method,
			"path", r.URL.Path,
			"route", route,
			"status", sw.status,
			"duration_ms", dur.Milliseconds(),
			"remote", r.RemoteAddr,
			"user_id", userID,
		)

		pathLabel := httpPathLabel(route)
		statusStr := strconvItoa(sw.status)

		if s.metrics != nil {
			s.metrics.IncCounter("http_requests_total",
				MetricLabel{"method", r.Method},
				MetricLabel{"path", pathLabel},
				MetricLabel{"status", statusStr},
			)
			s.metrics.ObserveHistogram("http_request_duration_ms",
				float64(dur.Milliseconds()),
				MetricLabel{"method", r.Method},
				MetricLabel{"path", pathLabel},
			)
		}

		// DogStatsD — emit request counter and latency histogram.
		if s.dd != nil {
			tags := []string{
				"method:" + r.Method,
				"path:" + pathLabel,
				"status_code:" + statusStr,
			}
			s.dd.Incr("http.requests", tags)
			s.dd.Histogram("http.latency_ms", float64(dur.Milliseconds()), tags)
		}
	})
}

// httpPathLabel returns a bounded label for HTTP metrics.
// We use the mux route pattern (e.g. "POST-/v1/chat/completions")
// instead of URL.Path so attacker-controlled unmatched paths cannot create
// unbounded metric cardinality. Dashes replace spaces so DogStatsD tags
// parse cleanly (spaces break tag parsing).
func httpPathLabel(route string) string {
	if route == "" {
		return "unmatched"
	}
	return strings.ReplaceAll(route, " ", "-")
}

// strconvItoa is a shim to avoid pulling strconv into every middleware file.
func strconvItoa(i int) string { return strconv.Itoa(i) }

// newRequestID returns a short, URL-safe request identifier. We avoid
// uuid here because request_id is hot-path and we don't need the entropy
// of a UUID — 12 base32 chars (~60 bits) is plenty to distinguish
// concurrent requests for trace correlation.
func newRequestID() string {
	const alphabet = "0123456789abcdefghijklmnopqrstuv"
	var b [12]byte
	if _, err := cryptoRand(b[:]); err != nil {
		// Fall back to a time-based id; collision risk is negligible for
		// log-correlation purposes.
		t := time.Now().UnixNano()
		return strconv.FormatInt(t, 36)
	}
	for i := range b {
		b[i] = alphabet[int(b[i])&31]
	}
	return string(b[:])
}

// statusWriter wraps http.ResponseWriter to capture the status code
// for logging. It also implements http.Flusher and http.Hijacker by
// delegating to the underlying writer, which is required for SSE
// streaming and WebSocket upgrade respectively.
type statusWriter struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (sw *statusWriter) WriteHeader(code int) {
	if !sw.wroteHeader {
		sw.status = code
		sw.wroteHeader = true
	}
	sw.ResponseWriter.WriteHeader(code)
}

func (sw *statusWriter) Flush() {
	if f, ok := sw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Hijack implements http.Hijacker by delegating to the underlying writer.
// This is required for WebSocket upgrade to work through middleware.
func (sw *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if hj, ok := sw.ResponseWriter.(http.Hijacker); ok {
		return hj.Hijack()
	}
	return nil, nil, errors.New("underlying ResponseWriter does not implement http.Hijacker")
}

// Unwrap returns the underlying ResponseWriter, allowing the http package
// and websocket libraries to discover interfaces like http.Hijacker.
func (sw *statusWriter) Unwrap() http.ResponseWriter {
	return sw.ResponseWriter
}

// extractBearerToken extracts the token from "Authorization: Bearer <token>".
func extractBearerToken(r *http.Request) string {
	auth := r.Header.Get("Authorization")
	if auth == "" {
		return ""
	}
	parts := strings.SplitN(auth, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "bearer") {
		return ""
	}
	return strings.TrimSpace(parts[1])
}
