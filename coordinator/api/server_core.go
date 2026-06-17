package api

import (
	"crypto/x509"
	"log/slog"
	"net/http"
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
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
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

	// ttftHardReject controls how the per-request TTFT admission ceiling
	// (5s+1ms/token) behaves when the best ESTIMATED time-to-first-token exceeds
	// it. The estimate's prefill term is not provider-measured and runs ~10x
	// pessimistic (see resolvedPrefillTPS), which made the legacy hard gate 429
	// the majority of serveable requests above ~550 prompt tokens. Default false:
	// the ceiling is a SOFT routing preference — when at least one provider passed
	// every routing and capacity gate, the request is served on the best-available
	// provider instead of being rejected. Set true
	// (EIGENINFERENCE_TTFT_HARD_REJECT=true) to restore the legacy hard 429.
	ttftHardReject bool

	// minDecodeTPS is the per-request sustained-decode floor (tokens/sec) passed
	// to the scheduler as PendingRequest.MinDecodeTPS. When > 0 the router prefers
	// providers that keep a newly admitted request at >= this rate (avoid
	// overpacking into degraded streams). Soft: never rejects on its own. Default
	// 0 (off). Set via EIGENINFERENCE_MIN_DECODE_TPS.
	minDecodeTPS float64

	// knownRuntimeManifest holds accepted runtime component hashes.
	// When set, providers whose runtime hashes don't match are marked as
	// unverified and excluded from routing (but not disconnected).
	knownRuntimeManifest *RuntimeManifest

	// settlements parks billing records for requests whose consumer disconnected
	// mid-stream, so a late provider terminal can settle them (or the reservation
	// is refunded on grace expiry). See settlement.go.
	settlements *settlementHolder
	// settleGrace overrides defaultTerminalSettleGrace (tests set it small).
	settleGrace time.Duration
	// zombieCanceller throttles cancels for chunks on abandoned streams. See zombie_stream.go.
	zombieCanceller *zombieStreamCanceller

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

	// serviceReservations avoids hot-row pre-router ledger debits for trusted
	// service accounts when enabled. Normal consumers still use ledger debits.
	serviceReservations *serviceReservationManager

	// consumerTokenLimiter / serviceTokenLimiter enforce per-account input
	// (ITPM) and output (OTPM) token-per-minute limits on inference endpoints,
	// the industry-standard token throttle alongside RPM. Nil means no token
	// limiting for that tier. Service accounts use serviceTokenLimiter.
	consumerTokenLimiter *ratelimit.TokenLimiter
	serviceTokenLimiter  *ratelimit.TokenLimiter
	// outputAdmissionEstimator enables service-account expected-output admission
	// for OTPM. Nil means disabled and preserves full max_tokens admission.
	outputAdmissionEstimator *ratelimit.OutputAdmissionEstimator

	// keyRPMLimiter / keyTokenLimiter enforce PER-KEY rate overrides (each key
	// may carry a different ceiling) on top of the per-account limiters above.
	// They only act when a key sets RPMLimit / ITPMLimit / OTPMLimit; otherwise
	// the key inherits the account-level limits. Nil disables per-key limiting.
	keyRPMLimiter   *ratelimit.Limiter
	keyTokenLimiter *ratelimit.KeyTokenLimiter

	// routeTelemetry is the bounded, non-blocking sink that persists
	// best-effort routing telemetry (inference-route records, outcome updates,
	// rejection ledger rows) off the request path. It is set by NewServer; a
	// Server built directly (e.g. &Server{} in tests) leaves it nil, and
	// submitTelemetry falls back to a per-write saferun.Go in that case.
	routeTelemetry *telemetrySink
}
