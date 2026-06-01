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
	"crypto/x509"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
)

const (
	apiKeyCacheTTL     = 60 * time.Second
	apiKeyCacheMaxSize = 1000
)

// Server is the main HTTP/WS server for the coordinator. It ties together
// the provider registry, key store, payment ledger, billing service, and HTTP routing.
type Server struct {
	registry               *registry.Registry
	store                  store.Store
	ledger                 *payments.Ledger
	billing                *billing.Service
	logger                 *slog.Logger
	mux                    *http.ServeMux
	challengeInterval      time.Duration     // 0 means use DefaultChallengeInterval
	skipChallenge          bool              // if true, skip attestation challenges entirely (testing only)
	privyAuth              *auth.PrivyAuth   // Privy JWT authentication (nil if not configured)
	adminEmails            map[string]bool   // emails that have admin access
	adminKey               string            // EIGENINFERENCE_ADMIN_KEY for admin endpoints
	mdmClient              *mdm.Client       // MicroMDM client for provider security verification
	stepCARootCert         *x509.Certificate // step-ca root CA for ACME cert verification
	stepCAIntermediateCert *x509.Certificate // step-ca intermediate CA

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
