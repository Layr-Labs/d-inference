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
// The coordinator runs in a GCP Confidential VM (AMD SEV). Consumer traffic
// arrives over HTTPS/TLS. The coordinator reads requests for routing but never
// logs prompt content.
package api

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
	"golang.org/x/mod/semver"
	"golang.org/x/sync/singleflight"
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
// 0.8.1 reverts v0.8.0's fleet default back to the CONTIGUOUS KV backend:
// the paged pool's physical-capacity policy sized fleet KV roughly 10x
// smaller than contiguous, and the resulting token-budget exhaustion
// dominated paged's throughput and prefix-adoption wins. Paged remains
// fully supported behind an explicit `engine_v2_kv_backend = "paged"` (see
// the provider's EngineV2Factory.prepareProductionBackend for the argument).
// 0.8.15 adds the exact Qwen3.8 dense VLM/NAX target and verified inline MTP
// assistant support; model-aware MTP defaults remain provider-side policy.
// Keep this fallback in sync with ProviderCore.version so dev/in-memory
// coordinators advertise the same floor as the Swift binary they expect.
var LatestProviderVersion = "0.8.16"

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
	if release := s.store.GetLatestRelease(defaultReleasePlatform); release != nil {
		return release.Version
	}
	return LatestProviderVersion
}

type approvedReleasePolicy struct {
	Version        string
	Platform       string
	Backend        string
	BinaryHash     string
	MetallibHash   string
	PythonHash     string
	RuntimeHash    string
	TemplateHashes map[string]string
}

type releaseTrustPolicySnapshot struct {
	Generation   uint64
	Required     bool
	ByBinaryHash map[string][]approvedReleasePolicy
}

// Server is the main HTTP/WS server for the coordinator. It ties together
// the provider registry, key store, payment ledger, billing service, and HTTP routing.
type Server struct {
	registry                      *registry.Registry
	store                         store.Store
	ledger                        *payments.Ledger
	billing                       *billing.Service
	baseRewards                   *baserewards.Engine
	logger                        *slog.Logger
	mux                           *http.ServeMux
	modelAliasMutationMu          sync.Mutex      // serializes cross-endpoint alias validation + persistence
	challengeInterval             time.Duration   // 0 means use DefaultChallengeInterval
	skipChallenge                 bool            // if true, skip attestation challenges entirely (testing only)
	allowDuplicateProviderSerials bool            // in-process multi-provider testbed only
	privyAuth                     *auth.PrivyAuth // Privy JWT authentication (nil if not configured)
	adminEmails                   map[string]bool // emails that have admin access
	adminKey                      string          // EIGENINFERENCE_ADMIN_KEY for admin endpoints
	mdmClient                     *mdm.Client     // MicroMDM client for provider security verification
	mdmScheduler                  *mdmVerificationScheduler
	mdmSchedulerConfig            MDMSchedulerConfig
	mdmWebhookSecret              string              // optional shared secret MicroMDM must present on the webhook
	profileSigner                 *profilesign.Signer // CMS signer for the /v1/enroll .mobileconfig (nil = serve unsigned)
	promptArtifacts               *promptcontract.Provisioner
	promptContract                *promptcontract.Client
	promptSupervisor              *promptcontract.Supervisor
	promptPreloader               *promptcontract.PreloadController
	exactCacheGaugeMu             sync.RWMutex
	exactCacheGaugeStatus         ExactCacheStatus
	exactCacheStatusCacheMu       sync.Mutex
	exactCacheStatusCache         ExactCacheStatus
	exactCacheStatusCacheExpires  time.Time
	codeAttestor                  apns.CodeIdentityAttestor // APNs code-identity attestor (nil = disabled; v0.6.0)
	codeResumeSender              func(string, protocol.CodeAttestationResumeChallenge) error
	codeResumeBeforeIdentityCheck func()              // test seam between cache match and challenge record
	codeResumeFallbackBeforeAPNs  func()              // test seam after nonce consume, before ctx recheck
	codeAttestThrottle            *codeAttestThrottle // per-device APNs push budget + reuse cache (v0.6.0)
	trustReuseCache               *trustReuseCache    // per-device trust-reuse cache: skip a fleet-wide live MDM herd on restart (DAR-326)
	trustReuseJournal             hardUntrustJournal
	trustRevocationMu             sync.Mutex
	trustSafetyMu                 sync.RWMutex
	trustSafetySticky             bool
	trustSafetyReplayBlocked      bool
	pendingHardUntrustKeyHashes   map[string]int
	trustAuthorityMu              sync.Mutex
	trustAuthority                *trustAuthorityLock
	trustReplayCtx                context.Context
	trustReplayCancel             context.CancelFunc
	trustReplayMu                 sync.Mutex
	trustReplayInFlight           map[string]struct{}
	// Connection-continuity coverage tracker: seKey → providerID of the live
	// covered connection. Advanced by the batched trustCoverageLoop and the
	// disconnect/shutdown sweeps (see trust_reuse.go).
	trustCoverageMu     sync.Mutex
	trustCoverage       map[string]string
	trustCoverageCtx    context.Context
	trustCoverageCancel context.CancelFunc

	// Graceful-drain state (DAR-327 Phase 1, zero-downtime upgrades). Set
	// coordinatorDraining=true before a restart/swap so the drain gate rejects
	// NEW inference requests with 429+Retry-After while already-admitted ones run
	// to completion; httpInflight counts requests currently inside the gate so
	// /readyz (and the deploy script) can wait for it to reach 0 before shutdown.
	// Deliberately named to avoid collision with the provider-side drain concepts
	// (protocol.ProviderDrainingForUpdate, registry.drainQueuedRequestsForModels):
	// this is purely the coordinator's own HTTP-ingress drain. See drain.go.
	httpInflight        atomic.Int64
	coordinatorDraining atomic.Bool

	// knownBinaryHashes is the set of accepted provider binary SHA-256 hashes.
	// When binaryHashPolicyConfigured is true, providers whose binary hash is
	// missing or doesn't match are rejected.
	// Auto-populated from active releases via SyncBinaryHashes().
	releasePolicySyncMu               sync.Mutex
	binaryHashPolicyMu                sync.RWMutex
	knownBinaryHashes                 map[string]bool
	manualKnownBinaryHashes           map[string]bool
	releaseKnownBinaryHashes          map[string]bool
	manualBinaryHashPolicyConfigured  bool
	releaseBinaryHashPolicyConfigured bool
	binaryHashPolicyConfigured        bool
	releaseTrustPolicy                atomic.Pointer[releaseTrustPolicySnapshot]
	releaseTrustPolicyGeneration      atomic.Uint64
	releaseInventoryEverConfigured    atomic.Bool

	// binaryHashEnforce gates whether a self-reported binaryHash mismatch actually
	// DEROUTES a provider. Default false as of v0.6.0: binaryHash is self-reported
	// (worthless against a malicious provider) and is demoted to drift telemetry —
	// APNs code-identity attestation is the real code-identity signal. The policy
	// machinery is retained for drift comparison and rollback
	// (EIGENINFERENCE_BINARYHASH_ENFORCE=true).
	binaryHashEnforce bool

	// ttftHardReject controls how the per-request TTFT admission ceiling
	// (configured base + 1ms/token) behaves when the best ESTIMATED
	// time-to-first-token exceeds it. The estimate's prefill term is not
	// provider-measured and runs ~10x
	// pessimistic (see resolvedPrefillTPS), which made the legacy hard gate 429
	// the majority of serveable requests above ~550 prompt tokens. Default false:
	// the ceiling is a SOFT routing preference — when at least one provider passed
	// every routing and capacity gate, the request is served on the best-available
	// provider instead of being rejected. Set true
	// (EIGENINFERENCE_TTFT_HARD_REJECT=true) to restore the legacy hard 429.
	ttftHardReject bool

	// firstContentDeadlineBase is the ordinary-model fixed term in the
	// request-absolute first-content budget. It is immutable after startup and
	// instance-owned; exact-model policy can only tighten it. Concurrent test
	// servers can exercise production and unit-test postures without racing on
	// process-global state.
	firstContentDeadlineBase time.Duration

	// rejectModels are requested aliases or resolved model IDs the coordinator
	// takes out of public/prefer-owner routing: every matching request is answered
	// with 429 + Retry-After at admission instead of being routed. This is a
	// deterministic per-model circuit breaker for unhealthy models (for example,
	// keep Gemma shed while allowing gpt-oss traffic with TTFT_HARD_REJECT=false).
	// Exclusive self-route bypasses this because it never falls back to the public
	// fleet and is useful for owner debugging. nil/empty = none.
	rejectModels map[string]bool

	// minDecodeTPS is the per-request sustained-decode floor (tokens/sec) passed
	// to the scheduler as PendingRequest.MinDecodeTPS. When > 0 the router prefers
	// providers that keep a newly admitted request at >= this rate (avoid
	// overpacking into degraded streams). Soft: never rejects on its own. Default
	// 0 (off). Set via EIGENINFERENCE_MIN_DECODE_TPS.
	minDecodeTPS float64

	// servabilityGate enables the smart early-429 admission gate: when
	// true, a request whose (prompt + max_tokens) cannot fit the model's context
	// window or any provider's structural token budget is rejected with an
	// uptime-NEUTRAL 429 + Retry-After at preflight (OpenRouter fails over)
	// instead of being admitted and failing as an uptime-DAMAGING 5xx. Default
	// false (behavior-neutral). Set via EIGENINFERENCE_SERVABILITY_GATE=true. See
	// registry.PredictServable + servability_gate.go. Independent of (and weaker
	// than) the always-on dispatch-exhausted reclassification of token-budget 5xx
	// → 429, which fixes the same failure on the actual provider-rejection path.
	servabilityGate bool

	// disableClientErrorStop is the kill switch for the C1 StatusCode-driven
	// non-retryable failover stop. Default false = stop ENABLED: a deterministic
	// provider client 4xx (400/413/422/415) returns ONCE instead of failing over up
	// to maxDispatchAttempts. Set EIGENINFERENCE_DISABLE_CLIENT_ERROR_STOP=true to
	// restore the pre-fix behavior (string-only classifyRejection failover).
	disableClientErrorStop bool

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

	// hedgeGov is the fleet-wide hedge admission governor (Routing v2 Phase 4):
	// the mutable half of the speculative-launch verdict — the global
	// concurrent-hedge counter and per-model win-rate EWMAs. One instance per
	// Server; runSpeculative consults it before every backup launch and
	// resolves it exactly once per launched hedge. See hedge_governor.go.
	hedgeGov *hedgeGovernor

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

	// chunkKeys memoizes the per-request NaCl shared key so streaming chunk
	// decryption skips the X25519 scalar multiplication per token. Zero value
	// is ready; entries are dropped on request completion/error and bounded
	// by chunkKeyCacheMax.
	chunkKeys chunkKeyCache

	// metrics is the in-process metrics registry exposed via /v1/admin/metrics
	// and used by internal counters/histograms. Never nil.
	metrics *Metrics

	// telemetryLimiter throttles telemetry ingestion per submitter.
	telemetryLimiter *telemetryLimiter

	// readCache memoizes pre-serialized JSON for read-heavy aggregation
	// endpoints (stats, leaderboard, model catalog, etc.). TTLs are
	// per-key. Never nil.
	readCache *ttlCache
	// statsRefresh owns the stats:v1 readCache entry (stats.go);
	// networkTotalsRefresh owns one network_totals:<window> entry per window
	// (network_totals.go). Both are driven by the refresher machinery in
	// cache_refresher.go.
	summaryWindowsFlights singleflight.Group
	statsRefresh          cacheRefresher
	networkTotalsRefresh  struct {
		queryMu sync.Mutex
		mu      sync.Mutex
		entries map[string]*cacheRefresher
	}

	// emitter writes coordinator-side telemetry events (panics, handler
	// failures, attestation failures, etc.). Set via SetEmitter; nil before
	// main.go wires it up.
	emitter *telemetry.Emitter

	// dd is the Datadog integration client for DogStatsD metrics and
	// Logs API event forwarding. Nil when DD is not configured.
	dd          *datadog.Client
	queueGauges queueGaugeState

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

	// profiler owns the per-request profile records and their dedicated sink
	// (system profiler). Nil on a Server built without NewServer.
	profiler *profiler
	// unknownRequestFrames counts provider frames for requests the coordinator
	// no longer tracks (zombie streams); exported on the fleet coordinator row.
	unknownRequestFrames atomic.Int64

	// mediaResolver fetches remote http(s) image_url/video_url links into
	// inline base64 data: URIs before the request body is E2E-encrypted to a
	// provider, so consumers can pass links instead of pre-encoding media
	// client-side (media_resolve.go). The coordinator is the single SSRF
	// chokepoint; the provider still only ever sees data: URIs. Set by
	// NewServer from env; nil (e.g. a &Server{} built directly in tests)
	// behaves as disabled and falls back to the legacy pre-dispatch rejection.
	mediaResolver *mediafetch.Resolver
	// routingScanSem bounds how many provider-selection scans (the
	// ReserveProviderEx/ReserveProviderWithPlan family — a read-lock walk of
	// ~1,260 providers per attempt) may run concurrently. During the
	// 2026-09-01 congestion collapse, retry-amplified inbound (~100 req/s of
	// retryable 429 traffic) times a fresh full scan per dispatch attempt
	// saturated every coordinator CPU (attempt-0 route p50 40ms → 4.6s,
	// success ~40%, 429s delivered after 11s) — a stable death loop. With the
	// semaphore, excess requests park cheaply on the channel instead of
	// piling onto the scheduler; one that cannot acquire within its remaining
	// first-content budget sheds as a capacity-shaped 429
	// (errRoutingScanSaturated). Capacity defaults to runtime.NumCPU()
	// (min 2); override via EIGENINFERENCE_ROUTING_CONCURRENCY
	// (SetRoutingConcurrency, called before serving starts).
	routingScanSem chan struct{}

	// routeLatencyEWMAMs is an EWMA of attempt-0 route latency (ReceivedAt →
	// RoutedAt, milliseconds), updated where RoutedAt is stamped in
	// dispatchWithReserver. estimateRetryAfter consults it: when routing
	// itself is degraded (EWMA > 1s) the returned Retry-After scales up so
	// upstream backoff actually relieves pressure — during the 2026-09-01
	// collapse the queue-depth heuristic returned 2s on an empty queue and
	// invited 2s retry storms. Guarded by routeLatencyMu (one tiny critical
	// section per request; no allocation).
	routeLatencyMu     sync.Mutex
	routeLatencyEWMAMs float64
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

func (s *Server) SetOutputAdmissionEstimator(estimator *ratelimit.OutputAdmissionEstimator) {
	s.outputAdmissionEstimator = estimator
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
	_, ok := s.applyTokenRateLimitWithAdmission(w, r, inputTokens, outputTokens)
	return ok
}

func (s *Server) applyTokenRateLimitWithAdmission(w http.ResponseWriter, r *http.Request, inputTokens, outputTokens int) (registry.TokenAdmission, bool) {
	admission := registry.TokenAdmission{AdmittedOutputTokens: outputTokens}
	accountID := consumerKeyFromContext(r.Context())
	if accountID == "admin" {
		return admission, true
	}

	// Resolve the account-tier token limiter (nil = no account-level token limit
	// for this caller, e.g. a service account with no service token limiter).
	tl := s.consumerTokenLimiter
	tier := "consumer"
	serviceAccount := false
	if user := auth.UserFromContext(r.Context()); user != nil && user.Role == store.RoleService {
		serviceAccount = true
		tier = "service"
		if s.serviceTokenLimiter != nil {
			tl = s.serviceTokenLimiter
		} else {
			tl = nil
		}
	}
	admission.AccountTier = tier
	if serviceAccount {
		if estimatedOutput, estimated := s.outputAdmissionEstimator.Estimate(outputTokens); estimated {
			admission.AdmittedOutputTokens = estimatedOutput
			admission.EstimatedOutput = true
		}
	}

	keyID, inRPS, inBurst, outRPS, outBurst, keyEnforced := s.keyTokenParams(r)
	admission.AccountOutputLimited = tl != nil && tl.HasOutputLimit()
	admission.KeyOutputLimited = keyEnforced && outRPS > 0 && outBurst > 0
	admission.KeyOutputRPS = outRPS
	admission.KeyOutputBurst = outBurst
	if admission.TracksOutput() {
		s.ddHistogram("ratelimit.output_admission.estimated_tokens", float64(admission.AdmittedOutputTokens), outputAdmissionTags(tier, admission.EstimatedOutput))
	}

	// Peek BOTH the per-key override and the account-level limiter before
	// consuming either. Only commit when both have capacity, so a rejection in
	// one limiter never debits the other (a per-key request that the account
	// bucket rejects must not drain the key's quota, and vice-versa).
	if keyEnforced {
		if ok, dim, retry := s.keyTokenLimiter.Peek(keyID, inputTokens, admission.AdmittedOutputTokens, inRPS, inBurst, outRPS, outBurst); !ok {
			s.writeTokenRateLimited(w, "key", dim, retry)
			return admission, false
		}
	}
	if tl != nil {
		if ok, dim, retry := tl.Peek(accountID, inputTokens, admission.AdmittedOutputTokens); !ok {
			setTokenRateLimitHeaders(w, tl, accountID)
			s.writeTokenRateLimited(w, tier, dim, retry)
			return admission, false
		}
	}

	// Both dimensions have capacity — commit to each.
	if keyEnforced {
		s.keyTokenLimiter.Commit(keyID, inputTokens, admission.AdmittedOutputTokens, inRPS, inBurst, outRPS, outBurst)
	}
	if tl != nil {
		tl.Commit(accountID, inputTokens, admission.AdmittedOutputTokens)
		setTokenRateLimitHeaders(w, tl, accountID)
	}
	return admission, true
}

func outputAdmissionTags(tier string, estimated bool) []string {
	if tier == "" {
		tier = "none"
	}
	return []string{"tier:" + tier, "estimated:" + strconv.FormatBool(estimated)}
}

func (s *Server) reconcileOutputAdmission(pr *registry.PendingRequest, actualOutputTokens int) {
	if pr == nil || !pr.TokenAdmission.TracksOutput() {
		return
	}
	admission := pr.TokenAdmission
	if actualOutputTokens < 0 {
		actualOutputTokens = 0
	}
	admittedOutputTokens := admission.AdmittedOutputTokens
	if admittedOutputTokens < 0 {
		admittedOutputTokens = 0
	}
	delta := actualOutputTokens - admittedOutputTokens
	if delta < 0 {
		delta = 0
	}
	tags := append(outputAdmissionTags(admission.AccountTier, admission.EstimatedOutput), "model:"+pr.Model)
	s.ddHistogram("ratelimit.output_admission.actual_tokens", float64(actualOutputTokens), tags)
	s.ddHistogram("ratelimit.output_admission.delta_tokens", float64(delta), tags)
	if delta == 0 {
		return
	}
	if admission.AccountOutputLimited {
		var tl *ratelimit.TokenLimiter
		switch admission.AccountTier {
		case "service":
			tl = s.serviceTokenLimiter
		default:
			tl = s.consumerTokenLimiter
		}
		if tl != nil {
			tl.DebitOutput(pr.ConsumerKey, delta)
		}
	}
	if admission.KeyOutputLimited && s.keyTokenLimiter != nil {
		s.keyTokenLimiter.DebitOutput(pr.KeyID, delta, admission.KeyOutputRPS, admission.KeyOutputBurst)
	}
	s.ddCount("ratelimit.output_admission.delta_tokens_total", int64(delta), tags)
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

	// main.go supplies the AppConfig-validated media-fetch config; a nil field
	// (bare ServerConfig{} literals, tests) falls back to the environment.
	mediaFetchCfg := mediafetch.ConfigFromEnv()
	if cfg.MediaFetch != nil {
		mediaFetchCfg = *cfg.MediaFetch
	}
	firstContentDeadlineBase := cfg.FirstContentDeadlineBase
	if firstContentDeadlineBase <= 0 {
		firstContentDeadlineBase = defaultFirstContentDeadlineBase
	}

	s := &Server{
		registry:                 reg,
		store:                    st,
		ledger:                   payments.NewLedger(st),
		logger:                   logger,
		mux:                      http.NewServeMux(),
		knownRuntimeManifest:     &RuntimeManifest{},
		metrics:                  NewMetrics(),
		telemetryLimiter:         newTelemetryLimiter(),
		readCache:                newTTLCache(),
		geoResolver:              newProviderGeoResolverFromEnv(logger),
		apiKeyCache:              make(map[string]apiKeyCacheEntry),
		codeAttestThrottle:       newCodeAttestThrottle(),
		trustReuseCache:          newTrustReuseCache(),
		mdmSchedulerConfig:       cfg.MDMScheduler,
		settlements:              newSettlementHolder(),
		zombieCanceller:          newZombieStreamCanceller(),
		hedgeGov:                 newHedgeGovernor(),
		serviceReservations:      newServiceReservationManager(st, cfg.ServiceReservations),
		routeTelemetry:           newTelemetrySink(logger, defaultTelemetrySinkCapacity, defaultTelemetrySinkWorkers),
		mediaResolver:            mediafetch.NewResolver(mediaFetchCfg, logger),
		firstContentDeadlineBase: firstContentDeadlineBase,
		routingScanSem:           make(chan struct{}, DefaultRoutingConcurrency()),
	}
	if _, clampedDown := trustReuseReconnectGapFromEnv(); clampedDown {
		logger.Warn("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP exceeds the 120s security ceiling; clamping DOWN",
			"requested", os.Getenv("EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP"),
			"allowance", maxTrustReuseReconnectGap,
			"reason", "a contiguous offline gap must stay below the RecoveryOS round-trip floor (Threat-Model T-036)",
		)
	}
	// Registry write-lock wait, by call site. This is the acceptance metric
	// for taking the recorders off the request path: today the wait is only
	// inferable from goroutine dumps.
	reg.SetLockWaitObserver(func(site string, wait time.Duration) {
		s.ddHistogram("registry.mu.write_wait_ms", float64(wait.Microseconds())/1000, []string{"site:" + site})
	})
	s.trustCoverage = make(map[string]string)
	s.trustCoverageCtx, s.trustCoverageCancel = context.WithCancel(context.Background())
	saferun.Go(logger, "trustCoverageLoop", s.trustCoverageLoop)
	if cfg.DurableTrustReuse {
		journalPath := cfg.TrustReuseJournalPath
		if strings.TrimSpace(journalPath) == "" {
			journalPath = resolveTrustReuseRevocationJournalPath()
		}
		s.trustReuseJournal = newFileHardUntrustJournal(journalPath)
		s.pendingHardUntrustKeyHashes = make(map[string]int)
		s.trustReplayCtx, s.trustReplayCancel = context.WithCancel(
			context.Background(),
		)
		s.trustReplayInFlight = make(map[string]struct{})
	}
	reg.SetRuntimeCapabilitiesPromotedHook(s.handleRuntimeCapabilitiesPromoted)
	// The per-identity gate locks that replaced the request-path registry
	// write lock (registry/gate_state.go) report any acquisition wait above
	// 1 ms here, tagged by recorder site, so the new locks stay observable.
	reg.SetGateWaitObserver(func(site string, wait time.Duration) {
		s.ddHistogram("registry.gate.wait_ms", float64(wait.Microseconds())/1000, []string{"site:" + site})
	})
	s.profiler = newProfilerFromEnv(s)
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
	s.releaseKey = cfg.ReleaseKey

	return s
}

func (s *Server) handleRuntimeCapabilitiesPromoted(providerID string) {
	provider := s.registry.GetProvider(providerID)
	if provider == nil {
		return
	}
	provider.Mu().Lock()
	backend, version := provider.Backend, provider.Version
	provider.Mu().Unlock()
	if !s.providerSupportsDesiredModels(backend, version) {
		return
	}
	entries := s.registry.DesiredModelsForProvider(providerID)
	if err := s.registry.SendDesiredModels(providerID, entries); err != nil {
		s.logger.Warn("failed to refresh desired_models after capability promotion",
			"provider_id", providerID,
			"error", err,
		)
	}
}

// submitTelemetry enqueues a best-effort telemetry write onto the non-blocking
// routing-telemetry sink. It never blocks the caller (the inference request
// path): when the sink's buffer is full the write is dropped and counted. name
// identifies the write for panic/drop diagnostics.
//
// Nil-safety: a Server constructed directly (e.g. &Server{} in tests, which
// never runs NewServer) has no sink. In that case it falls back to the previous
// behavior — a per-write panic-safe goroutine — so those tests keep working.
func (s *Server) submitTelemetry(name string, fn func()) {
	if s.routeTelemetry != nil {
		s.routeTelemetry.submit(fn)
		return
	}
	saferun.Go(s.logger, name, fn)
}

// Close releases background resources owned by the Server.
func (s *Server) Close() {
	// Graceful-shutdown continuity sweep: stop the periodic coverage loop,
	// then persist the exact shutdown instant for every covered provider so a
	// short deploy reconnects into the continuity fast-skip on the next
	// coordinator instead of a fleet-wide live MDM herd. A crash skips this —
	// the last periodic write stands and the gap is over-estimated (fail-safe).
	if s.trustCoverageCancel != nil {
		s.trustCoverageCancel()
	}
	s.finalTrustCoverageSweep()
	if s.trustReplayCancel != nil {
		s.trustReplayCancel()
	}
	if s.mdmScheduler != nil {
		s.mdmScheduler.Close()
	}
	if s.promptPreloader != nil {
		s.promptPreloader.Close()
	}
	if s.promptArtifacts != nil {
		s.promptArtifacts.Close()
	}
	if s.routeTelemetry != nil {
		// Bounded flush: buffered route rows are written before main's deferred
		// store Close (registered earlier, so it runs after this) tears down the
		// pool. A stuck store cannot hold shutdown past the deadline; whatever
		// is still unwritten then is counted as dropped by the sink.
		if !s.routeTelemetry.closeAndWait(telemetrySinkShutdownFlush) && s.logger != nil {
			s.logger.Warn("routing telemetry sink did not finish flushing before the shutdown deadline",
				"deadline", telemetrySinkShutdownFlush,
				"dropped_total", s.routeTelemetry.dropped.Load(),
			)
		}
	}
	s.trustAuthorityMu.Lock()
	if s.trustAuthority != nil {
		_ = s.trustAuthority.Close()
		s.trustAuthority = nil
	}
	s.trustAuthorityMu.Unlock()
	if s.profiler != nil {
		s.profiler.close()
	}
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

// SetBaseRewards configures the provider base-rewards engine (off unless the
// EIGENINFERENCE_BASE_REWARDS flag is set; nil = disabled).
func (s *Server) SetBaseRewards(e *baserewards.Engine) {
	s.baseRewards = e
}

// BaseRewards returns the base-rewards engine, or nil when disabled.
func (s *Server) BaseRewards() *baserewards.Engine {
	return s.baseRewards
}

func (s *Server) SetChallengeInterval(d time.Duration) {
	s.challengeInterval = d
}

func (s *Server) SetSkipChallenge(skip bool) {
	s.skipChallenge = skip
}

// SetAllowDuplicateProviderSerialsForTesting lets the in-process E2E testbed
// emulate multiple physical providers on one Mac. Production never calls it.
func (s *Server) SetAllowDuplicateProviderSerialsForTesting(allow bool) {
	s.allowDuplicateProviderSerials = allow
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
	if client != nil && s.mdmScheduler == nil {
		s.mdmScheduler = newMDMVerificationScheduler(s, s.mdmSchedulerConfig, mdmSchedulerDeps{})
	}
}

// StartMDMScheduler starts the single durable dispatcher and fixed worker pool.
func (s *Server) StartMDMScheduler() {
	if s.mdmScheduler != nil {
		s.mdmScheduler.Start()
	}
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
			RequiredProviderCapabilities: append(
				[]string{}, row.RequiredProviderCapabilities...),
		})
	}
	// Advance the prompt-artifact generation before publishing new routing
	// hashes. Cache planning also carries and compares the aggregate hash, so
	// either side of this handoff is fail-cold under concurrent requests.
	if err := s.reconcilePromptArtifacts(registryRows); err != nil {
		s.logger.Error("prompt artifact catalog reconcile rejected", "error", err)
	}
	s.registry.SetModelCatalog(entries)
	s.logger.Info("model registry catalog synced to registry", "active_models", len(entries))

	s.syncModelAliases(registryRows)
	// Catalog capability changes can invalidate an in-flight desired-model
	// prefetch even when alias pointers did not change. Re-publish the filtered
	// desired state immediately; newly ineligible providers receive an empty
	// set, which cancels stale reconciliation work.
	s.fanOutDesiredModels()
	s.invalidateCatalogCache()
}

// syncModelAliases loads standard rollout aliases first, then resolves
// OpenRouter-only aliases through either a standard alias or an active concrete
// catalog model. OpenRouter-only targets route requests but do not participate
// in provider convergence or canonical public naming.
func (s *Server) syncModelAliases(registryRows []store.ModelRegistryRecord) {
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		s.logger.Error("model alias sync failed", "error", err)
		return
	}
	resolved := make(map[string]registry.AliasTarget, len(aliases))
	activeConcreteModels := make(map[string]struct{}, len(registryRows))
	for _, row := range registryRows {
		if row.ActiveVersion != nil {
			activeConcreteModels[row.ID] = struct{}{}
		}
	}
	for _, a := range aliases {
		if !a.Active || a.OpenRouterOnly || a.DesiredBuild == "" {
			continue
		}
		resolved[a.AliasID] = registry.AliasTarget{
			Desired:  a.DesiredBuild,
			Previous: a.PreviousBuild,
			Retired:  a.RetiredBuilds,
		}
	}
	for _, a := range aliases {
		if !a.Active || !a.OpenRouterOnly {
			continue
		}
		var target registry.AliasTarget
		var ok bool
		if openRouterAliasUsesConcreteSource(a) {
			if _, ok = activeConcreteModels[a.SourceModel]; ok {
				target = registry.AliasTarget{Desired: a.SourceModel}
			}
		} else {
			target, ok = resolved[a.SourceModel]
		}
		if !ok {
			s.logger.Warn("OpenRouter alias source is unavailable", "alias_id", a.AliasID, "source_model", a.SourceModel)
			continue
		}
		target.OpenRouterOnly = true
		resolved[a.AliasID] = target
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
	for _, typeFilter := range []string{"", "text"} {
		for _, includeAliases := range []bool{false, true} {
			s.readCache.Invalidate(modelCatalogCacheKey(typeFilter, includeAliases))
		}
	}
	// /v1/models entry memo + list bodies (both include_builds values) and the
	// OpenRouter feed are derived from the same catalog; drop them too so an
	// admin alias/registry change is visible on the next request instead of
	// after their 2s/5s TTLs (which remain the bound for out-of-band DB edits).
	for _, includeBuilds := range []bool{false, true} {
		s.readCache.Invalidate(modelEntriesCacheKey(includeBuilds))
		s.readCache.Invalidate(modelListBodyCacheKey(includeBuilds))
	}
	s.readCache.Invalidate(openRouterFeedCacheKey)
	// stats:v1 is deliberately NOT evicted here: the stats refresher recomputes
	// it every minute, and evicting it made every concurrent /v1/stats request
	// rerun the multi-second usage analytics statements.
}

// SetKnownBinaryHashes configures the set of accepted provider binary hashes.
// SetBinaryHashEnforcement toggles whether a self-reported binaryHash mismatch
// deroutes a provider. Default false (v0.6.0): binaryHash is demoted to drift
// telemetry; APNs code-identity attestation is the real signal. Enable only for
// rollback or to test the legacy enforcement path.
func (s *Server) SetBinaryHashEnforcement(enabled bool) {
	s.binaryHashEnforce = enabled
}

// SetTTFTHardReject toggles the per-request TTFT admission ceiling between a
// hard 429 (true, legacy) and a soft routing preference (false, default). See
// the ttftHardReject field for rationale. Call before serving starts.
func (s *Server) SetTTFTHardReject(enabled bool) {
	s.ttftHardReject = enabled
}

// SetRejectModels sets the requested/resolved model IDs to 429 at public
// admission. Call before serving starts.
func (s *Server) SetRejectModels(models map[string]bool) {
	if len(models) == 0 {
		s.rejectModels = nil
		return
	}
	copy := make(map[string]bool, len(models))
	for model, reject := range models {
		if !reject {
			continue
		}
		model = strings.TrimSpace(model)
		if model == "" {
			continue
		}
		copy[model] = true
	}
	if len(copy) == 0 {
		s.rejectModels = nil
		return
	}
	s.rejectModels = copy
}

func (s *Server) modelShed(resolved, requested string) bool {
	if len(s.rejectModels) == 0 {
		return false
	}
	return s.rejectModels[resolved] || s.rejectModels[requested]
}

// SetMinDecodeTPS sets the per-request sustained-decode floor (tokens/sec) the
// scheduler uses as a soft routing preference. <= 0 disables it. See the
// minDecodeTPS field. Call before serving starts.
func (s *Server) SetMinDecodeTPS(tps float64) {
	if tps < 0 {
		tps = 0
	}
	s.minDecodeTPS = tps
}

// DefaultRoutingConcurrency is the built-in routing-scan semaphore capacity:
// one scan per CPU (a scan is pure CPU under the registry read lock), floored
// at 2 so a tiny container never serializes routing entirely. Exported so
// main.go can log the effective default alongside the env override.
func DefaultRoutingConcurrency() int {
	n := runtime.NumCPU()
	if n < 2 {
		n = 2
	}
	return n
}

// SetRoutingConcurrency replaces the routing-scan semaphore with one of the
// given capacity (EIGENINFERENCE_ROUTING_CONCURRENCY). Values < 2 clamp to 2.
// Call before serving starts — replacing the channel while scans are in
// flight would strand slots.
func (s *Server) SetRoutingConcurrency(n int) {
	if n < 2 {
		n = 2
	}
	s.routingScanSem = make(chan struct{}, n)
}

// scanSlotResult is the outcome of acquireRoutingScanSlot. Client
// disconnection is distinguished from acquisition timeout so callers route a
// vanished caller onto the existing client-gone terminal (cancelled outcome,
// refund, no response body) and NEVER onto the routing_saturated 429 /
// rejection-ledger path.
type scanSlotResult int

const (
	scanSlotAcquired scanSlotResult = iota
	scanSlotTimeout
	scanSlotClientGone
)

// acquireRoutingScanSlot blocks until a provider-selection scan slot is free,
// the wait budget elapses, or done fires (client gone). On scanSlotTimeout the
// caller sheds the attempt as capacity-shaped (errRoutingScanSaturated)
// instead of piling another scan onto saturated CPUs; on scanSlotClientGone it
// takes its ordinary client-gone path. A nil semaphore (a &Server{} built
// directly in tests) admits immediately, preserving legacy behavior for bare
// fixtures; a nil done channel never fires.
func (s *Server) acquireRoutingScanSlot(wait time.Duration, done <-chan struct{}) scanSlotResult {
	if s.routingScanSem == nil {
		return scanSlotAcquired
	}
	select {
	case s.routingScanSem <- struct{}{}:
		return scanSlotAcquired
	default:
	}
	clientGone := func() bool {
		select {
		case <-done:
			return true
		default:
			return false
		}
	}
	if wait <= 0 {
		if clientGone() {
			return scanSlotClientGone
		}
		return scanSlotTimeout
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case s.routingScanSem <- struct{}{}:
		return scanSlotAcquired
	case <-timer.C:
		if clientGone() {
			return scanSlotClientGone
		}
		return scanSlotTimeout
	case <-done:
		return scanSlotClientGone
	}
}

// releaseRoutingScanSlot returns a slot taken by acquireRoutingScanSlot.
func (s *Server) releaseRoutingScanSlot() {
	if s.routingScanSem == nil {
		return
	}
	<-s.routingScanSem
}

// SetServabilityGate toggles the smart early-429 admission gate. See the
// servabilityGate field. Call before serving starts.
func (s *Server) SetServabilityGate(enabled bool) {
	s.servabilityGate = enabled
}

// SetDisableClientErrorStop is the kill switch for the C1 client-shape failover
// stop. true restores pre-fix behavior (deterministic provider 4xx fails over up
// to maxDispatchAttempts). Default (false) = stop enabled. Call before serving.
func (s *Server) SetDisableClientErrorStop(disabled bool) {
	s.disableClientErrorStop = disabled
}

// SetLongPromptThreshold configures the estimated-prompt-token count at/above
// which the scheduler applies the long-prompt fastest-tier routing preference.
// 0 disables it (behavior-neutral). It is a package-level scheduler knob (like
// the prefill/decode ratio), so this delegates to the registry. Call before
// serving starts. SOFT bias only — no TTFT 429 is introduced.
func (s *Server) SetLongPromptThreshold(tokens int) {
	registry.SetLongPromptThreshold(tokens)
}

// SetLongPromptPrefillWeight configures the prefill-term multiplier the scheduler
// applies to long prompts. Values < 1 clamp to 1.0 (no amplification).
// Delegates to the registry; call before serving starts.
func (s *Server) SetLongPromptPrefillWeight(weight float64) {
	registry.SetLongPromptPrefillWeight(weight)
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

// SetReleaseKey configures the scoped release key for GitHub Actions.
func (s *Server) SetReleaseKey(key string) {
	s.releaseKey = key
}

// SetCoordinatorKey installs the X25519 keypair the coordinator publishes
// for sender-to-coordinator request encryption. Pass nil to disable.
func (s *Server) SetCoordinatorKey(k *e2e.CoordinatorKey) {
	s.coordinatorKey = k
}

// SyncBinaryHashes rebuilds knownBinaryHashes from all active releases.
// Called at startup and after release changes.
//
// An inventory read failure is an OPERATIONAL condition, not a security signal:
// with a previously published policy the last-known-good snapshot is retained
// untouched (mirroring SyncRuntimeManifest's nil handling) so a store hiccup
// can never deroute a healthy fleet. Only a cold start with no prior snapshot
// publishes a deny-all generation — there is nothing known-good to retain, and
// startup refuses to proceed on the returned error.
func (s *Server) SyncBinaryHashes() error {
	s.releasePolicySyncMu.Lock()
	defer s.releasePolicySyncMu.Unlock()
	releases, err := s.store.ListReleasesWithError()
	if err != nil {
		if last := s.releaseTrustPolicy.Load(); last != nil {
			s.logger.Error("release inventory unavailable; retaining last-known-good release policy",
				"generation", last.Generation,
				"error", err,
			)
			s.ddIncr("release_policy.sync_failure", []string{"outcome:retained_last_known_good"})
			return fmt.Errorf("sync binary hashes: %w", err)
		}
		// Cold start: no last-known-good policy exists. Publish deny-all so a
		// half-started coordinator cannot route on an unknown inventory.
		generation := s.releaseTrustPolicyGeneration.Add(1)
		trustSnapshot := &releaseTrustPolicySnapshot{
			Generation:   generation,
			Required:     true,
			ByBinaryHash: make(map[string][]approvedReleasePolicy),
		}
		s.releaseTrustPolicy.Store(trustSnapshot)
		if s.registry != nil {
			s.registry.SetReleasePolicyGeneration(trustSnapshot.Generation, true, nil)
		}
		s.binaryHashPolicyMu.Lock()
		s.releaseKnownBinaryHashes = make(map[string]bool)
		s.releaseBinaryHashPolicyConfigured = true
		s.rebuildBinaryHashPolicyLocked()
		s.binaryHashPolicyMu.Unlock()
		s.logger.Error("release inventory unavailable at cold start; published deny-all release policy",
			"generation", generation,
			"error", err,
		)
		s.ddIncr("release_policy.sync_failure", []string{"outcome:cold_start_deny_all"})
		return fmt.Errorf("sync binary hashes: %w", err)
	}

	hashes := make(map[string]bool)
	generation := s.releaseTrustPolicyGeneration.Add(1)
	everConfigured := s.releaseInventoryEverConfigured.Load()
	if len(releases) > 0 {
		s.releaseInventoryEverConfigured.Store(true)
		everConfigured = true
	}
	trustSnapshot := &releaseTrustPolicySnapshot{
		Generation:   generation,
		Required:     everConfigured,
		ByBinaryHash: make(map[string][]approvedReleasePolicy),
	}

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
		templates := make(map[string]string)
		for _, pair := range strings.Split(r.TemplateHashes, ",") {
			parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
			if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
				templates[parts[0]] = parts[1]
			}
		}
		trustSnapshot.ByBinaryHash[normalized] = append(
			trustSnapshot.ByBinaryHash[normalized],
			approvedReleasePolicy{
				Version: r.Version, Platform: r.Platform, Backend: r.Backend,
				BinaryHash: normalized, MetallibHash: r.MetallibHash,
				PythonHash: r.PythonHash, RuntimeHash: r.RuntimeHash,
				TemplateHashes: templates,
			})
	}
	s.releaseTrustPolicy.Store(trustSnapshot)
	if s.registry != nil {
		// Evidence still approved under the NEW snapshot is carried forward at
		// the new generation. For a REQUIRED policy the registry returns every
		// provider NOT carried forward — including providers that held no
		// evidence at all (first required activation over a cold fleet) — and
		// each one is re-challenged immediately instead of waiting for the
		// periodic ticker (whose interval outlives the request queue).
		needChallenge := s.registry.SetReleasePolicyGeneration(
			trustSnapshot.Generation, trustSnapshot.Required,
			func(evidence registry.ApplicationEvidence) bool {
				return releaseEvidenceStillApproved(trustSnapshot, evidence)
			})
		for _, providerID := range needChallenge {
			if provider := s.registry.GetProvider(providerID); provider != nil {
				provider.RequestImmediateChallenge()
			}
		}
		if len(needChallenge) > 0 {
			s.logger.Info("release policy refresh left providers without current evidence; re-challenging immediately",
				"generation", trustSnapshot.Generation,
				"providers", len(needChallenge),
			)
			s.ddIncr("release_policy.evidence_invalidated", []string{fmt.Sprintf("providers:%d", len(needChallenge))})
		}
	}

	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = policyConfigured || everConfigured
	s.rebuildBinaryHashPolicyLocked()
	knownHashCount := len(s.knownBinaryHashes)
	effectivePolicyConfigured := s.binaryHashPolicyConfigured
	s.binaryHashPolicyMu.Unlock()

	s.logger.Info("binary hashes synced from releases", "known_hashes", knownHashCount, "policy_configured", effectivePolicyConfigured)
	return nil
}

// convergeReleasePolicyWithCommittedRelease folds an already-committed release
// registration into the in-memory release trust policy when the post-mutation
// inventory read failed. GET /v1/releases/latest serves the committed row
// straight from the store, so retaining the pre-registration snapshot would
// distribute a release the policy can never authorize — providers installing it
// could never earn evidence and, with no background resync, would stay
// unroutable indefinitely. The merged snapshot is exactly what a successful
// rebuild over "last-known-good inventory + this row" publishes: entries for
// the same version/platform are replaced, everything else is carried forward
// (so still-approved evidence survives and routine registration never deroutes
// the fleet), and the newly saved release is immediately authorized. The next
// successful sync rebuilds from the exact inventory.
func (s *Server) convergeReleasePolicyWithCommittedRelease(release *store.Release, cause error) {
	s.releasePolicySyncMu.Lock()
	defer s.releasePolicySyncMu.Unlock()

	normalized, err := normalizeSHA256Hex(release.BinaryHash, "release.binary_hash")
	if err != nil {
		// Unreachable for the register handler (the hash was validated before
		// the row committed), and a full rebuild would skip such a row too.
		s.logger.Error("committed release has invalid binary hash; policy not converged",
			"version", release.Version, "platform", release.Platform, "error", err)
		return
	}

	generation := s.releaseTrustPolicyGeneration.Add(1)
	s.releaseInventoryEverConfigured.Store(true)
	trustSnapshot := &releaseTrustPolicySnapshot{
		Generation:   generation,
		Required:     true,
		ByBinaryHash: make(map[string][]approvedReleasePolicy),
	}
	if last := s.releaseTrustPolicy.Load(); last != nil {
		for hash, policies := range last.ByBinaryHash {
			for _, policy := range policies {
				if policy.Version == release.Version && policy.Platform == release.Platform {
					continue // replaced by this registration
				}
				trustSnapshot.ByBinaryHash[hash] = append(trustSnapshot.ByBinaryHash[hash], policy)
			}
		}
	}
	templates := make(map[string]string)
	for _, pair := range strings.Split(release.TemplateHashes, ",") {
		parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
		if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
			templates[parts[0]] = parts[1]
		}
	}
	trustSnapshot.ByBinaryHash[normalized] = append(
		trustSnapshot.ByBinaryHash[normalized],
		approvedReleasePolicy{
			Version: release.Version, Platform: release.Platform, Backend: release.Backend,
			BinaryHash: normalized, MetallibHash: release.MetallibHash,
			PythonHash: release.PythonHash, RuntimeHash: release.RuntimeHash,
			TemplateHashes: templates,
		})
	s.releaseTrustPolicy.Store(trustSnapshot)
	if s.registry != nil {
		needChallenge := s.registry.SetReleasePolicyGeneration(
			trustSnapshot.Generation, trustSnapshot.Required,
			func(evidence registry.ApplicationEvidence) bool {
				return releaseEvidenceStillApproved(trustSnapshot, evidence)
			})
		for _, providerID := range needChallenge {
			if provider := s.registry.GetProvider(providerID); provider != nil {
				provider.RequestImmediateChallenge()
			}
		}
		if len(needChallenge) > 0 {
			s.ddIncr("release_policy.evidence_invalidated", []string{fmt.Sprintf("providers:%d", len(needChallenge))})
		}
	}
	hashes := make(map[string]bool, len(trustSnapshot.ByBinaryHash))
	for hash := range trustSnapshot.ByBinaryHash {
		hashes[hash] = true
	}
	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = true
	s.rebuildBinaryHashPolicyLocked()
	s.binaryHashPolicyMu.Unlock()

	s.logger.Warn("release inventory unreadable after registration; converged policy from the committed release",
		"version", release.Version,
		"platform", release.Platform,
		"generation", generation,
		"error", cause,
	)
	s.ddIncr("release_policy.sync_failure", []string{"outcome:converged_from_mutation"})
}

// convergeReleasePolicyWithCommittedDeactivation folds an already-committed
// release deactivation into the in-memory release trust policy when the
// post-mutation inventory read failed. Retaining the pre-deactivation snapshot
// would keep authorizing the deactivated release indefinitely — there is no
// background resync, so in a force=true emergency pull of a compromised
// release the affected providers would keep routing until an admin retried.
// The merged snapshot is exactly what a successful rebuild over
// "last-known-good inventory minus this row" publishes: entries for the
// deactivated version/platform are dropped, everything else is carried forward
// (so still-approved evidence survives and pulling one release never deroutes
// the rest of the fleet), and providers whose evidence rested on the
// deactivated release are invalidated and kicked for an immediate
// re-challenge. The next successful sync rebuilds from the exact inventory.
func (s *Server) convergeReleasePolicyWithCommittedDeactivation(version, platform string, cause error) {
	s.releasePolicySyncMu.Lock()
	defer s.releasePolicySyncMu.Unlock()

	last := s.releaseTrustPolicy.Load()
	generation := s.releaseTrustPolicyGeneration.Add(1)
	// Deactivation never un-configures the inventory: once releases have been
	// published the evidence gate stays required, exactly as a full rebuild
	// over the remaining (possibly empty) release set would keep it.
	required := s.releaseInventoryEverConfigured.Load()
	if last != nil && last.Required {
		required = true
	}
	trustSnapshot := &releaseTrustPolicySnapshot{
		Generation:   generation,
		Required:     required,
		ByBinaryHash: make(map[string][]approvedReleasePolicy),
	}
	if last != nil {
		for hash, policies := range last.ByBinaryHash {
			for _, policy := range policies {
				if policy.Version == version && policy.Platform == platform {
					continue // removed by this deactivation
				}
				trustSnapshot.ByBinaryHash[hash] = append(trustSnapshot.ByBinaryHash[hash], policy)
			}
		}
	}
	s.releaseTrustPolicy.Store(trustSnapshot)
	if s.registry != nil {
		needChallenge := s.registry.SetReleasePolicyGeneration(
			trustSnapshot.Generation, trustSnapshot.Required,
			func(evidence registry.ApplicationEvidence) bool {
				return releaseEvidenceStillApproved(trustSnapshot, evidence)
			})
		for _, providerID := range needChallenge {
			if provider := s.registry.GetProvider(providerID); provider != nil {
				provider.RequestImmediateChallenge()
			}
		}
		if len(needChallenge) > 0 {
			s.ddIncr("release_policy.evidence_invalidated", []string{fmt.Sprintf("providers:%d", len(needChallenge))})
		}
	}
	hashes := make(map[string]bool, len(trustSnapshot.ByBinaryHash))
	for hash := range trustSnapshot.ByBinaryHash {
		hashes[hash] = true
	}
	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = len(hashes) > 0 || required
	s.rebuildBinaryHashPolicyLocked()
	s.binaryHashPolicyMu.Unlock()

	s.logger.Warn("release inventory unreadable after deactivation; converged policy from the committed deactivation",
		"version", version,
		"platform", platform,
		"generation", generation,
		"error", cause,
	)
	s.ddIncr("release_policy.sync_failure", []string{"outcome:converged_from_mutation"})
}

// releaseEvidenceStillApproved reports whether previously granted application
// evidence remains approved under a freshly built release-policy snapshot: the
// same binary hash still maps to an active release with the same version,
// platform, and backend, and that release's metallib hash is unchanged. These
// are the ONLY facts application evidence proves — python/runtime/per-family
// template facts were deliberately removed (mlx-swift providers never report
// them; requiring them made evidence underivable fleet-wide, 2026-08-31
// incident). Binary hash and metallib fail closed on absence or mismatch.
func releaseEvidenceStillApproved(
	snapshot *releaseTrustPolicySnapshot,
	evidence registry.ApplicationEvidence,
) bool {
	if evidence.BinaryHash == "" || evidence.MetallibHash == "" {
		return false
	}
	for _, candidate := range snapshot.ByBinaryHash[evidence.BinaryHash] {
		if candidate.Version != evidence.Version ||
			candidate.Platform != evidence.Platform ||
			candidate.Platform == "" {
			continue
		}
		// Legacy release rows may carry an empty backend (the column was added
		// with an empty default); treat it as matching the evidence backend,
		// mirroring deriveApprovedReleaseTransition.
		if candidate.Backend != "" && candidate.Backend != evidence.Backend {
			continue
		}
		expectedMetallib, err := normalizeSHA256Hex(candidate.MetallibHash, "release.metallib_hash")
		if err != nil || expectedMetallib != evidence.MetallibHash {
			continue
		}
		return true
	}
	return false
}

// Closed outcome set for application-evidence derivation. Every
// deriveApprovedReleaseTransition return path records exactly one of these as
// a release_evidence.outcome DogStatsD counter tag so a candidate coordinator
// can be judged in SHADOW mode from per-reason fleet counts instead of a
// silent boolean (the 2026-08-31 zero-capacity deploys were undiagnosable
// precisely because every rejection branch looked identical). No hashes,
// keys, serials, or tokens ride on these tags.
const (
	evidenceOutcomeGranted                 = "granted"
	evidenceReasonPrecondition             = "precondition"
	evidenceReasonInvalidBinaryHash        = "invalid_binary_hash"
	evidenceReasonPolicyUnavailable        = "policy_unavailable"
	evidenceReasonPolicyNotRequired        = "policy_not_required"
	evidenceReasonProcessIdentity          = "process_identity"
	evidenceReasonRuntimeGate              = "runtime_gate"
	evidenceReasonVersionFloor             = "version_floor"
	evidenceReasonRegistrationHashMismatch = "registration_hash_mismatch"
	evidenceReasonNoActiveRelease          = "no_active_release"
	evidenceReasonMetallibMismatch         = "metallib_mismatch"
)

// recordReleaseEvidenceOutcome counts one application-evidence derivation
// outcome. No-op without DogStatsD.
func (s *Server) recordReleaseEvidenceOutcome(outcome string) {
	s.ddIncr("release_evidence.outcome", []string{"outcome:" + outcome})
}

// evidenceRejected records the typed rejection reason and returns the empty
// derivation result.
func (s *Server) evidenceRejected(reason string) (approvedReleaseTransitionFact, registry.ApplicationEvidence, bool) {
	s.recordReleaseEvidenceOutcome(reason)
	return approvedReleaseTransitionFact{}, registry.ApplicationEvidence{}, false
}

func (s *Server) deriveApprovedReleaseTransition(
	provider *registry.Provider,
	resp *protocol.AttestationResponseMessage,
	statusFieldsTrusted bool,
) (approvedReleaseTransitionFact, registry.ApplicationEvidence, bool) {
	if provider == nil || resp == nil || !statusFieldsTrusted ||
		resp.SIPEnabled == nil || !*resp.SIPEnabled ||
		resp.SecureBootEnabled == nil || !*resp.SecureBootEnabled ||
		provider.ChallengeShouldStop() {
		return s.evidenceRejected(evidenceReasonPrecondition)
	}
	freshHash, err := normalizeSHA256Hex(resp.BinaryHash, "binary_hash")
	if err != nil {
		return s.evidenceRejected(evidenceReasonInvalidBinaryHash)
	}
	snapshot := s.releaseTrustPolicy.Load()
	if snapshot == nil {
		return s.evidenceRejected(evidenceReasonPolicyUnavailable)
	}

	provider.Mu().Lock()
	version, backend, processKey := provider.Version, provider.Backend, provider.PublicKey
	apnsToken := provider.APNsDeviceToken
	runtimeVerified := provider.RuntimeVerified
	manifestChecked := provider.RuntimeManifestChecked
	metallibVerified := provider.MetallibVerified
	attested := provider.AttestationResult
	provider.Mu().Unlock()
	// An APNs device token is deliberately NOT required: application evidence
	// proves the live binary/runtime is an active approved release, while APNs
	// token possession is enforced exclusively by the code-identity gate (with
	// its own grace semantics). Tokenless legacy/headless providers with a
	// valid signed challenge must still derive and keep evidence.
	if !snapshot.Required {
		return s.evidenceRejected(evidenceReasonPolicyNotRequired)
	}
	if processKey == "" || attested == nil || !attested.Valid ||
		attested.PublicKey == "" || attested.SerialNumber == "" {
		return s.evidenceRejected(evidenceReasonProcessIdentity)
	}
	if !runtimeVerified || !manifestChecked || !metallibVerified {
		return s.evidenceRejected(evidenceReasonRuntimeGate)
	}
	if s.minProviderVersion != "" &&
		(version == "" || semverLess(version, s.minProviderVersion)) {
		return s.evidenceRejected(evidenceReasonVersionFloor)
	}
	// Registration-time binary_hash is optional and the production fleet omits
	// it. The fresh hash is carried by this already-signature-verified challenge
	// from the same attested SE identity and is still required to match an active
	// release below. When registration did carry a hash, keep the stronger
	// cross-check and fail closed on a mismatch.
	if strings.TrimSpace(attested.BinaryHash) != "" {
		attestedHash, hashErr := normalizeSHA256Hex(attested.BinaryHash, "attested binary_hash")
		if hashErr != nil || attestedHash != freshHash {
			return s.evidenceRejected(evidenceReasonRegistrationHashMismatch)
		}
	}

	// Legacy release rows can carry an empty backend: the migration added the
	// column with an empty default and registration accepts an omitted backend.
	// Such rows MUST NOT leave providers permanently unroutable — an empty
	// backend matches the provider-reported backend (an exact match is
	// preferred when both exist), and the derived fact/evidence is stamped with
	// the provider-reported backend so routing's evidence.Backend == p.Backend
	// check keeps holding.
	var current approvedReleasePolicy
	found := false
	for _, candidate := range snapshot.ByBinaryHash[freshHash] {
		if candidate.Version == version && candidate.Backend == backend &&
			candidate.Platform != "" {
			current = candidate
			found = true
			break
		}
	}
	if !found {
		for _, candidate := range snapshot.ByBinaryHash[freshHash] {
			if candidate.Version == version && candidate.Backend == "" &&
				candidate.Platform != "" {
				current = candidate
				current.Backend = backend
				found = true
				break
			}
		}
	}
	if !found {
		return s.evidenceRejected(evidenceReasonNoActiveRelease)
	}
	if !releaseMetallibMatches(current, resp) {
		return s.evidenceRejected(evidenceReasonMetallibMismatch)
	}

	approvedFrom := make(map[string]struct{})
	for binaryHash := range snapshot.ByBinaryHash {
		if approvedTransitionPredecessor(
			snapshot, binaryHash,
			current.Platform, current.Backend, current.Version,
		) {
			approvedFrom[binaryHash] = struct{}{}
		}
	}
	metallibHash, _ := normalizeSHA256Hex(
		resp.TemplateHashes["mlx_metallib"], "mlx_metallib")
	fact := approvedReleaseTransitionFact{
		Approved: true, BinaryHash: freshHash, Version: current.Version,
		Platform: current.Platform, Backend: current.Backend,
		PolicyGeneration:         snapshot.Generation,
		ApprovedFromBinaryHashes: approvedFrom,
	}
	evidence := registry.ApplicationEvidence{
		SEPublicKey: attested.PublicKey, Serial: attested.SerialNumber,
		ProcessPublicKey: processKey, APNsToken: apnsToken,
		BinaryHash: freshHash,
		Version:    current.Version, Platform: current.Platform,
		Backend:      current.Backend,
		MetallibHash: metallibHash, VerifiedAt: time.Now().UTC(),
		PolicyGeneration: snapshot.Generation,
	}
	s.recordReleaseEvidenceOutcome(evidenceOutcomeGranted)
	return fact, evidence, true
}

// releaseMetallibMatches verifies the ONE release-specific runtime fact both
// sides always hold: the release row's metallib hash must equal the provider's
// reported mlx_metallib template hash (both normalized 64-hex; absence on
// either side fails closed). Nothing else is compared here by design — the
// python plane is gone (mlx-swift providers hardcode it nil), and release
// rows' per-model-family template hashes were CI fabrications (hashed from
// CDN jinja files by release-swift.yml) that no provider ever reported;
// requiring provider coverage of those made application evidence underivable
// for 100% of the production fleet (2026-08-31 zero-capacity incident).
// Binary-hash ↔ active-release matching is the caller's job.
func releaseMetallibMatches(policy approvedReleasePolicy, resp *protocol.AttestationResponseMessage) bool {
	if policy.MetallibHash == "" {
		return false
	}
	expectedMetallib, err := normalizeSHA256Hex(policy.MetallibHash, "release.metallib_hash")
	if err != nil {
		return false
	}
	gotMetallib, err := normalizeSHA256Hex(resp.TemplateHashes["mlx_metallib"], "mlx_metallib")
	return err == nil && gotMetallib == expectedMetallib
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
func (s *Server) SyncRuntimeManifest() error {
	releases, err := s.store.ListReleasesWithError()
	if err != nil {
		s.logger.Warn("SyncRuntimeManifest: release inventory unavailable; keeping existing manifest",
			"error", err)
		return fmt.Errorf("sync runtime manifest: %w", err)
	}

	// Minimum provider version is set manually via EIGENINFERENCE_MIN_PROVIDER_VERSION
	// env var. It is NOT auto-derived from the latest release — pushing a new release
	// should not instantly knock all existing providers offline.

	// Every hash — python, runtime, AND each template name including
	// mlx_metallib — is unioned into a SET across ALL active releases.
	// Releases overlap in production for the whole self-update window
	// (providers poll for updates every 30 minutes), so the manifest must
	// accept the runtime facts of every release a connected provider may
	// legitimately be running. Template hashes used to be single-valued per
	// name (newest release wins): registering v0.8.16 replaced the v0.8.15
	// metallib hash and derouted ~1,180 still-current providers at their next
	// challenge (2026-09-03 fleet brownout). Deactivating a release is the
	// mechanism that removes its hashes; iteration order is irrelevant.
	manifest := NewRuntimeManifest()
	hasAny := false
	for _, r := range releases {
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
		if manifest.addTemplateHashPairs(r.TemplateHashes) {
			hasAny = true
		}
		if r.MetallibHash != "" {
			normalized, err := normalizeSHA256Hex(r.MetallibHash, "release.metallib_hash")
			if err != nil {
				s.logger.Warn("invalid release metallib hash ignored",
					"version", r.Version,
					"platform", r.Platform,
					"error", err,
				)
			} else if manifest.AddTemplateHash("mlx_metallib", normalized) {
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
			"template_hash_sets", manifest.templateHashSetSizes(),
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
			return nil
		}
		s.knownRuntimeManifest = nil
	}

	s.revalidateConnectedProvidersAgainstRuntimePolicy()
	return nil
}

// convergeRuntimeManifestWithCommittedRelease folds an already-committed
// release registration into the runtime manifest when the post-mutation
// inventory read failed, so a transient store hiccup cannot leave the manifest
// rejecting the runtime facts of the release that /v1/releases/latest is
// already distributing. Every hash set — including each per-template-name
// set — is additive, exactly like a full rebuild (which unions every active
// release): the previous release's fleet keeps passing while the newly saved
// release is accepted too. The next successful sync rebuilds from the exact
// inventory.
func (s *Server) convergeRuntimeManifestWithCommittedRelease(release *store.Release, cause error) {
	merged := s.knownRuntimeManifest.clone()
	contributed := false
	if release.PythonHash != "" {
		merged.PythonHashes[release.PythonHash] = true
		contributed = true
	}
	if release.RuntimeHash != "" {
		merged.RuntimeHashes[release.RuntimeHash] = true
		contributed = true
	}
	if merged.addTemplateHashPairs(release.TemplateHashes) {
		contributed = true
	}
	if release.MetallibHash != "" {
		if normalized, err := normalizeSHA256Hex(release.MetallibHash, "release.metallib_hash"); err == nil &&
			merged.AddTemplateHash("mlx_metallib", normalized) {
			contributed = true
		}
	}
	if !contributed {
		// The committed release carries no runtime facts; a full rebuild would
		// republish the union of the remaining releases — the current manifest.
		return
	}
	s.knownRuntimeManifest = merged
	s.logger.Warn("release inventory unreadable after registration; converged runtime manifest from the committed release",
		"version", release.Version,
		"platform", release.Platform,
		"error", cause,
	)
	s.revalidateConnectedProvidersAgainstRuntimePolicy()
}

// convergeRuntimeManifestWithCommittedDeactivation folds an already-committed
// release deactivation into the runtime manifest when the post-mutation
// inventory read failed. Unlike registration (where the new release's facts
// are simply unioned in), deactivation cannot blindly subtract the pulled
// release's hashes — another active release may share them — so the manifest
// is rebuilt from the live release trust snapshot, which at this point already
// excludes the deactivated version/platform (SyncBinaryHashes either succeeded
// or was converged from the same committed deactivation first). Every hash
// set — including each per-template-name set — is the union of the remaining
// authorized releases, exactly like the full rebuild. Active releases whose
// binary hash failed normalization are absent from the snapshot and thus from
// this approximation; the next successful sync rebuilds from the exact
// inventory.
func (s *Server) convergeRuntimeManifestWithCommittedDeactivation(version, platform string, cause error) {
	merged := NewRuntimeManifest()
	hasAny := false
	if snapshot := s.releaseTrustPolicy.Load(); snapshot != nil {
		for _, policies := range snapshot.ByBinaryHash {
			for _, policy := range policies {
				if policy.PythonHash != "" {
					merged.PythonHashes[policy.PythonHash] = true
					hasAny = true
				}
				if policy.RuntimeHash != "" {
					merged.RuntimeHashes[policy.RuntimeHash] = true
					hasAny = true
				}
				for name, hash := range policy.TemplateHashes {
					if merged.AddTemplateHash(name, hash) {
						hasAny = true
					}
				}
				if policy.MetallibHash != "" {
					if normalized, err := normalizeSHA256Hex(policy.MetallibHash, "release.metallib_hash"); err == nil &&
						merged.AddTemplateHash("mlx_metallib", normalized) {
						hasAny = true
					}
				}
			}
		}
	}
	if !hasAny {
		// The deactivated row committed, so releases exist(ed) but none of the
		// remaining authorized ones carry runtime facts: explicit withdrawal,
		// exactly like the full rebuild's "releases exist but none have
		// hashes" branch. Providers proving the pulled release's facts must
		// not keep passing the manifest gate.
		merged = nil
	}
	s.knownRuntimeManifest = merged
	s.logger.Warn("release inventory unreadable after deactivation; converged runtime manifest from the retained policy snapshot",
		"version", version,
		"platform", platform,
		"error", cause,
	)
	s.revalidateConnectedProvidersAgainstRuntimePolicy()
}

func (s *Server) revalidateConnectedProvidersAgainstRuntimePolicy() {
	// Release-inventory errors are already guarded in SyncRuntimeManifest, which
	// returns the error before reaching this function.
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

		// Manifest policy is coordinator-owned and can be withdrawn, rotated,
		// or rolled back independently of the connected process. Rebuild all
		// policy-derived state from scratch, but preserve FreshCodeAttested:
		// that proof remains bound to this connection's token, keys, and code.
		// The token/key/code/trust invalidation paths clear it separately.
		provider.RuntimeVerified = false
		provider.RuntimeManifestChecked = false
		provider.MetallibVerified = false
		provider.RuntimeCapabilities = nil

		if s.knownRuntimeManifest == nil {
			// Manifest was withdrawn — keep the process proof, but deroute the
			// provider until policy once again approves its reported runtime.
		} else if s.minProviderVersion != "" &&
			version != "" &&
			semverLess(version, s.minProviderVersion) {
			s.ddIncr("provider_version_below_minimum", []string{"gate:manifest_sync", "version:" + version})
		} else {
			runtimeOK, _ := s.verifyRuntimeHashesForBackend(
				backend,
				pythonHash,
				runtimeHash,
				templateHashes,
			)
			provider.RuntimeVerified = runtimeOK
			provider.RuntimeManifestChecked = runtimeOK
			provider.MetallibVerified = runtimeOK &&
				runtimeManifestApprovesMetallib(
					s.knownRuntimeManifest, templateHashes)
		}
		provider.Mu().Unlock()
		if err := s.registry.ReconcileAttestedRuntimeCapabilities(providerID); err != nil {
			s.logger.Warn("runtime policy capability reconciliation failed",
				"provider_id", providerID, "error", err)
		}
		if cleared := s.registry.ClearIneligiblePendingModelLoads(providerID); cleared > 0 {
			s.logger.Info("cleared pending model loads after runtime policy revocation",
				"provider_id", providerID, "count", cleared)
		}
	}
}

func runtimeManifestApprovesMetallib(
	manifest *RuntimeManifest,
	reported map[string]string,
) bool {
	if manifest == nil {
		return false
	}
	return templateHashAccepted(manifest.TemplateHashes["mlx_metallib"], reported["mlx_metallib"])
}

// RuntimeManifest holds the set of accepted hashes for provider runtime components.
// When configured, the coordinator verifies provider-reported hashes against
// this manifest at registration and during periodic attestation challenges.
//
// Every field is a SET: the manifest is the UNION of every ACTIVE release's
// runtime facts, and a provider passes when its reported value is one of the
// accepted values for that component. TemplateHashes is a set PER template
// name (mlx_metallib included). It must never collapse to a single value per
// name: releases overlap in production for the whole self-update window, and a
// single-valued mlx_metallib entry derouted ~1,180 providers still running the
// previous release the moment the next one was registered (2026-09-03).
// Deactivating a release is the mechanism that removes its values.
type RuntimeManifest struct {
	PythonHashes   map[string]bool            `json:"python_hashes"`   // set of accepted Python runtime hashes
	RuntimeHashes  map[string]bool            `json:"runtime_hashes"`  // set of accepted inference runtime hashes
	TemplateHashes map[string]map[string]bool `json:"template_hashes"` // template_name -> set of accepted hashes
}

// NewRuntimeManifest returns an empty manifest with every set allocated.
func NewRuntimeManifest() *RuntimeManifest {
	return &RuntimeManifest{
		PythonHashes:   make(map[string]bool),
		RuntimeHashes:  make(map[string]bool),
		TemplateHashes: make(map[string]map[string]bool),
	}
}

// AddTemplateHash records value as an accepted hash for template name and
// reports whether anything was recorded. Values are trimmed and lower-cased so
// membership is case-insensitive (SHA-256 hex) and identical on the
// registration, challenge, and revalidation paths; empty names/values are
// ignored.
func (m *RuntimeManifest) AddTemplateHash(name, value string) bool {
	name = strings.TrimSpace(name)
	value = strings.ToLower(strings.TrimSpace(value))
	if name == "" || value == "" {
		return false
	}
	if m.TemplateHashes == nil {
		m.TemplateHashes = make(map[string]map[string]bool)
	}
	accepted := m.TemplateHashes[name]
	if accepted == nil {
		accepted = make(map[string]bool)
		m.TemplateHashes[name] = accepted
	}
	accepted[value] = true
	return true
}

// addTemplateHashPairs unions a release row's "name=hash,name=hash" list into
// the manifest and reports whether any entry was recorded.
func (m *RuntimeManifest) addTemplateHashPairs(raw string) bool {
	added := false
	for _, pair := range strings.Split(raw, ",") {
		parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
		if len(parts) == 2 && m.AddTemplateHash(parts[0], parts[1]) {
			added = true
		}
	}
	return added
}

// clone deep-copies the manifest; a nil receiver yields an empty manifest.
func (m *RuntimeManifest) clone() *RuntimeManifest {
	out := NewRuntimeManifest()
	if m == nil {
		return out
	}
	for hash := range m.PythonHashes {
		out.PythonHashes[hash] = true
	}
	for hash := range m.RuntimeHashes {
		out.RuntimeHashes[hash] = true
	}
	for name, accepted := range m.TemplateHashes {
		for hash := range accepted {
			out.AddTemplateHash(name, hash)
		}
	}
	return out
}

// templateHashSetSizes renders "name=count" pairs (sorted by name) for logs,
// so a sync line shows how many releases' values each template accepts.
func (m *RuntimeManifest) templateHashSetSizes() string {
	names := make([]string, 0, len(m.TemplateHashes))
	for name := range m.TemplateHashes {
		names = append(names, name)
	}
	sort.Strings(names)
	parts := make([]string, 0, len(names))
	for _, name := range names {
		parts = append(parts, fmt.Sprintf("%s=%d", name, len(m.TemplateHashes[name])))
	}
	return strings.Join(parts, ",")
}

// templateHashAccepted reports whether got is one of the accepted hashes for
// a template (case-insensitive; empty values never match).
func templateHashAccepted(accepted map[string]bool, got string) bool {
	got = strings.ToLower(strings.TrimSpace(got))
	return got != "" && accepted[got]
}

// sortedTemplateHashes lists a template's accepted hashes deterministically
// for diagnostics and the public manifest endpoint.
func sortedTemplateHashes(accepted map[string]bool) []string {
	out := make([]string, 0, len(accepted))
	for hash := range accepted {
		out = append(out, hash)
	}
	sort.Strings(out)
	return out
}

// semverGreater returns true when a has higher SemVer precedence than b,
// including the numeric/alphanumeric prerelease identifier rules. Invalid
// non-empty versions sort below valid versions so minimum-version gates fail
// closed.
func semverGreater(a, b string) bool {
	if a == "" {
		return false
	}
	if b == "" {
		return true
	}
	av := a
	if !strings.HasPrefix(av, "v") {
		av = "v" + av
	}
	bv := b
	if !strings.HasPrefix(bv, "v") {
		bv = "v" + bv
	}
	aValid, bValid := semver.IsValid(av), semver.IsValid(bv)
	switch {
	case aValid && bValid:
		return semver.Compare(av, bv) > 0
	case aValid:
		return true
	default:
		return false
	}
}

// semverLess returns true if version a is less than version b.
func semverLess(a, b string) bool {
	return semverGreater(b, a)
}

// SetRuntimeManifest configures the known-good runtime manifest for provider
// verification. Pass nil to disable runtime verification (all providers pass).
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
	scoped := NewRuntimeManifest()
	scopedReportedTemplates := make(map[string]string)

	if accepted := manifest.TemplateHashes["mlx_metallib"]; len(accepted) > 0 {
		scoped.TemplateHashes["mlx_metallib"] = accepted
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
		// Each template name maps to the SET of hashes accepted across every
		// active release; the reported value must be one of them.
		for name, accepted := range manifest.TemplateHashes {
			if len(accepted) == 0 {
				continue
			}
			expected := "one of " + strings.Join(sortedTemplateHashes(accepted), ",")
			got, ok := templateHashes[name]
			if !ok || strings.TrimSpace(got) == "" {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       "(missing)",
				})
				continue
			}
			if !templateHashAccepted(accepted, got) {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       got,
				})
			}
		}
		for name, got := range templateHashes {
			if len(manifest.TemplateHashes[name]) == 0 {
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
	if cached, ok := s.readCache.Get(runtimeManifestCacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}
	var resp map[string]any
	if s.knownRuntimeManifest == nil {
		resp = map[string]any{"configured": false}
	} else {
		// template_hashes is rendered as name -> sorted list of every hash
		// accepted across the active releases: the manifest is a union, not a
		// single expected value per template.
		templates := make(map[string][]string, len(s.knownRuntimeManifest.TemplateHashes))
		for name, accepted := range s.knownRuntimeManifest.TemplateHashes {
			templates[name] = sortedTemplateHashes(accepted)
		}
		resp = map[string]any{
			"configured":      true,
			"python_hashes":   s.knownRuntimeManifest.PythonHashes,
			"runtime_hashes":  s.knownRuntimeManifest.RuntimeHashes,
			"template_hashes": templates,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode manifest"))
		return
	}
	s.readCache.Set(runtimeManifestCacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}

// maxMDMWebhookBodyBytes caps the MicroMDM webhook body. SecurityInfo /
// DevicePropertiesAttestation responses are a few KB; 1 MiB is generous headroom
// while preventing an unauthenticated caller from exhausting memory via an
// unbounded body.
const maxMDMWebhookBodyBytes = 1 << 20 // 1 MiB

// maxRequestBodyBytes is the global ceiling bodyLimitMiddleware applies to every
// request body so no endpoint can be OOM'd by an unbounded POST. It's a coarse
// outer bound that clears every legitimate body with headroom; the hot paths
// self-cap tighter on top (the plaintext-inference path at 16 MiB, sized to the
// provider WS frame budget — see maxInferenceBodyBytes).
const maxRequestBodyBytes = 64 << 20 // 64 MiB

// maxControlPlaneBodyBytes is the tight cap for small unauthenticated
// control-plane JSON (enroll, device token, admin auth) — far below the global
// ceiling so these exposed endpoints buffer at most a few KiB.
const maxControlPlaneBodyBytes = 64 << 10 // 64 KiB

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
// serve time. coordinator/api/install.sh is generated byte-for-byte from the
// canonical scripts/install.sh by scripts/sync-install-embed.sh.
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
	// Install script — served from the generated embed with the coordinator URL
	// substituted per environment.
	s.mux.HandleFunc("GET /install.sh", func(w http.ResponseWriter, r *http.Request) {
		rendered := strings.ReplaceAll(string(installScript), installScriptPlaceholder, s.resolveBaseURL(r))
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		io.WriteString(w, rendered)
	})

	// Health check — no auth required.
	s.mux.HandleFunc("GET /health", s.handleHealth)
	// Aggregate exact-cache rollout health. Contains no provider/model/account
	// identity and is safe for canary automation.
	s.mux.HandleFunc("GET /v1/cache/status", s.handleExactCacheStatus)

	// Readiness probe — no auth required. Reports graceful-drain state so load
	// balancers and the deploy script treat a draining coordinator as not-ready
	// (503) and can wait for inflight==0 before restart. See drain.go (DAR-327).
	s.mux.HandleFunc("GET /readyz", s.handleReadyz)

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
	// drainGate is the OUTERMOST wrapper: while the coordinator is draining for a
	// restart/upgrade it rejects NEW inference requests with 429+Retry-After
	// before any auth/decrypt work, and otherwise counts the request as in-flight
	// so /readyz can report when it's safe to shut down (DAR-327 Phase 1).
	//
	// IMPORTANT: ANY future provider-routed inference endpoint (e.g.
	// /v1/audio/transcriptions, /v1/images/generations, /v1/embeddings) MUST also
	// be wrapped in s.drainGate(...). An ungated route won't 429 during drain and,
	// because it isn't counted in httpInflight, won't be seen by WaitForInflightZero
	// — so a graceful shutdown could cut it off mid-flight. Add new dispatch routes
	// here, gated, alongside the four below.
	s.mux.HandleFunc("POST /v1/chat/completions", s.drainGate(s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleChatCompletions)))))
	s.mux.HandleFunc("POST /v1/responses", s.drainGate(s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleChatCompletions))))) // Responses API — same handler, auto-detects input vs messages
	s.mux.HandleFunc("POST /v1/completions", s.drainGate(s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleCompletions)))))
	s.mux.HandleFunc("POST /v1/messages", s.drainGate(s.requireAuth(s.rateLimitConsumer(s.sealedTransport(s.handleAnthropicMessages)))))
	s.mux.HandleFunc("GET /v1/models", s.requireAuth(s.handleListModels))
	// Dedicated OpenRouter provider feed — pure OpenRouter schema, no Darkbloom metadata.
	s.mux.HandleFunc("GET /v1/models/openrouter", s.requireAuth(s.handleListModelsOpenRouter))
	// OpenAI "retrieve model" — {id...} matches slashed HuggingFace-style ids;
	// the literal /v1/models/openrouter and /v1/models/capacity routes win.
	s.mux.HandleFunc("GET /v1/models/{id...}", s.requireAuth(s.handleGetModel))

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

	s.mux.HandleFunc("GET /v1/provider/account-earnings", s.requireAuth(s.handleAccountEarnings))

	// Account-scoped provider dashboard.
	s.mux.HandleFunc("GET /v1/me/providers", s.requirePrivyAuth(s.handleMyProviders))
	s.mux.HandleFunc("GET /v1/me/summary", s.requirePrivyAuth(s.handleMySummary))
	// Alias-aware owned live-model ids for the console's self-route key picker.
	s.mux.HandleFunc("GET /v1/me/self-route-models", s.requirePrivyAuth(s.handleMySelfRouteModels))
	// Ownership-checked hard delete of a retired/offline machine's record(s).
	s.mux.HandleFunc("DELETE /v1/me/providers/{id}", s.requirePrivyAuth(s.rateLimitFinancial(s.handleDeleteMyProvider)))

	// MDM enrollment — generates the per-device .mobileconfig (SCEP + MDM).
	// No auth needed — trust comes from MDM SecurityInfo verification after
	// enrollment, not from possession of the profile.
	s.mux.HandleFunc("POST /v1/enroll", s.handleEnroll)

	// Attestation status — public, no auth needed. Raw device identity and MDA
	// certificates remain coordinator-private because the leaf embeds serial/UDID.
	s.mux.HandleFunc("GET /v1/providers/attestation", s.handleProviderAttestation)

	// Capacity snapshot — no auth needed. Upstream routers poll this.
	s.mux.HandleFunc("GET /v1/models/capacity", s.handleModelsCapacity)

	// Platform stats — no auth needed. Frontend dashboard uses this.
	s.mux.HandleFunc("GET /v1/stats", s.handleStats)

	// Public leaderboard + network totals — no auth, pseudonymized,
	// 5-min/1-min cache.
	s.mux.HandleFunc("GET /v1/leaderboard", s.handleLeaderboard)
	s.mux.HandleFunc("GET /v1/network/totals", s.handleNetworkTotals)
	s.mux.HandleFunc("GET /v1/network/series", s.handleNetworkSeries)

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

	// A single bank withdrawal experience, with separate payout lifecycles.
	s.mux.HandleFunc("POST /v1/billing/stripe/quote", s.requirePrivyAuth(s.rateLimitFinancial(s.handleGlobalPayoutQuote)))
	s.mux.HandleFunc("POST /v1/billing/stripe/global/webhook", s.handleGlobalPayoutWebhook)
	// Stripe Payouts (Connect Express) — bank/card withdrawals.
	s.mux.HandleFunc("POST /v1/billing/stripe/onboard", s.requirePrivyAuth(s.rateLimitFinancial(s.handleStripeOnboard)))
	s.mux.HandleFunc("GET /v1/billing/stripe/status", s.requireAuth(s.handleStripeStatus))
	s.mux.HandleFunc("POST /v1/billing/withdraw/stripe", s.requirePrivyAuth(s.rateLimitFinancial(s.handleStripeWithdraw)))
	s.mux.HandleFunc("GET /v1/billing/stripe/withdrawals", s.requireAuth(s.handleStripeWithdrawals))
	// requirePrivyAuth (not requireAuth): both of these are account-management
	// operations — a leaked inference API key must not be able to detach the
	// user's payout account, nor mint a dashboard session that can point their
	// earnings at a different bank account.
	//
	// The dashboard route additionally carries rateLimitFinancial: every call
	// is a live Stripe POST that mints a credential, so an authenticated
	// session must not be able to loop it and burn the platform's Stripe
	// request capacity. Chained INSIDE requirePrivyAuth because the limiter
	// keys on the account ID the auth middleware puts in the request context.
	s.mux.HandleFunc("POST /v1/billing/stripe/dashboard", s.requirePrivyAuth(s.rateLimitFinancial(s.handleStripeDashboardLink)))
	s.mux.HandleFunc("DELETE /v1/billing/stripe/account", s.requirePrivyAuth(s.handleStripeUnlink))
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
	// OpenRouter-only feed aliases clone a standard alias while exposing custom
	// provider id, marketplace slug, and Hugging Face identity.
	s.mux.HandleFunc("GET /v1/admin/models/openrouter-aliases", s.handleOpenRouterAliasList)
	s.mux.HandleFunc("POST /v1/admin/models/openrouter-aliases", s.handleOpenRouterAliasUpsert)
	s.mux.HandleFunc("DELETE /v1/admin/models/openrouter-aliases/{aliasID}", s.handleOpenRouterAliasDelete)
	// Public model aliases (stable names → concrete builds). More-specific
	// patterns take precedence over the POST /v1/admin/models/ subtree below.
	s.mux.HandleFunc("GET /v1/admin/models/aliases", s.handleModelAliasList)
	s.mux.HandleFunc("POST /v1/admin/models/aliases", s.handleModelAliasUpsert)
	s.mux.HandleFunc("DELETE /v1/admin/models/aliases/{aliasID}", s.handleModelAliasDelete)
	s.mux.HandleFunc("POST /v1/admin/models/", s.handleAdminModelRegistryAction)
	s.mux.HandleFunc("GET /v1/admin/releases", s.handleAdminListReleases)     // admin key or Privy admin
	s.mux.HandleFunc("DELETE /v1/admin/releases", s.handleAdminDeleteRelease) // admin key or Privy admin

	// Historical admin state export (DAR-70) — streams the TEE-sealed /data
	// archive used for the completed EigenCloud migration. Always registered, but
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

	// Retain the client-telemetry route for mixed-version compatibility. The
	// handler returns 410 before reading a request body; coordinator-owned
	// operational telemetry remains separate.
	s.mux.HandleFunc("POST /v1/telemetry/events", s.handleTelemetryIngest)

	// Explicit provider log reports
	s.mux.HandleFunc("POST /v1/provider/log-report", s.requireAuth(s.handleUploadLogReport))
	s.mux.HandleFunc("GET /v1/admin/log-reports/{id}", s.requireAuth(s.handleGetLogReport))

	// Metrics snapshot (admin only)
	s.mux.HandleFunc("GET /v1/admin/metrics", s.handleAdminMetrics)
	s.mux.HandleFunc("GET /v1/admin/base-rewards", s.handleAdminBaseRewards)

	// Network utilization snapshot (admin only) — handler enforces admin auth
	// internally via requireAdminKey.
	s.mux.HandleFunc("GET /v1/admin/utilization", s.handleAdminUtilization)

	// Graceful drain toggle (admin only) — sets the coordinator into drain mode
	// before a restart/upgrade so new inference requests get 429 while in-flight
	// ones finish. Wrapped with requireAuth (the SAME pattern as the other
	// isAdminAuthorized/requireAdminKey endpoints, e.g. invite codes) so a Privy
	// admin JWT is parsed into the request context AND the admin key is accepted
	// as a pseudo-account; handleAdminDrain then authorizes via isAdminAuthorized
	// (admin key OR Privy admin). Registered before the /v1/ catch-all. Note:
	// /readyz stays unauthenticated. See drain.go (DAR-327 Phase 1).
	s.mux.HandleFunc("POST /v1/admin/drain", s.requireAuth(s.handleAdminDrain))

	// Routing telemetry (admin-gated; metadata only — no prompt/response content).
	// Browse as JSON or stream a CSV/NDJSON download for offline analysis.
	// See docs/design/routing-telemetry-and-calibration.md §6. Handlers
	// enforce admin auth internally via requireAdminKey.
	s.mux.HandleFunc("GET /v1/admin/routes", s.handleAdminRoutes)
	s.mux.HandleFunc("GET /v1/admin/routes/export", s.handleAdminRoutesExport)
	s.mux.HandleFunc("GET /v1/admin/profiles", s.handleAdminProfiles)
	s.mux.HandleFunc("GET /v1/admin/profiles/export", s.handleAdminProfilesExport)
	s.mux.HandleFunc("GET /v1/admin/snapshots", s.handleAdminSnapshots)
	s.mux.HandleFunc("GET /v1/admin/snapshots/export", s.handleAdminSnapshotsExport)
	s.mux.HandleFunc("GET /v1/admin/rejections", s.handleAdminRejections)
	s.mux.HandleFunc("GET /v1/admin/rejections/export", s.handleAdminRejectionsExport)

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
	s.registerExactCacheGauges()
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
			perModel := s.registry.ModelProviderSnapshot()
			for model, count := range perModel {
				s.ddGauge("providers.per_model", float64(count), []string{"model:" + model})
			}
			// Per-model queue depth/age (fleet_gauges.go).
			s.emitPerModelQueueGauges(perModel)
			for ver, count := range s.registry.ProviderCountByVersion() {
				s.ddGauge("providers.per_version", float64(count), []string{"version:" + ver})
			}
			// Trust-state cohort gauges — alert when self_signed/untrusted grows.
			for _, b := range s.registry.ProviderCountByTrustStatus() {
				s.ddGauge("providers.by_trust_status", float64(b.Count),
					[]string{"trust_level:" + b.TrustLevel, "status:" + b.Status})
			}
			// Stuck-cohort breakdown — distinguishes never-enrolled from
			// enrolled-but-SecurityInfo-timing-out so we know if the problem is
			// provider-side enrollment or APNs/MDM delivery.
			for reason, count := range s.registry.ProviderCountByMDMFailure() {
				s.ddGauge("providers.by_mdm_failure", float64(count), []string{"reason:" + reason})
			}
			if s.minProviderVersion != "" {
				s.ddGauge("coordinator.min_provider_version_set", 1, []string{"min_version:" + s.minProviderVersion})
			}
			if q := s.registry.Queue(); q != nil {
				s.ddGauge("request_queue.depth", float64(q.TotalSize()), nil)
			}
			s.emitExactCacheDDGauges()
			s.emitStoreCacheGauges()
			// Network utilization — demand/capacity across the warm-serving and
			// token-budget axes, plus a per-model breakdown.
			util := s.registry.NetworkUtilizationSnapshot()
			s.ddGauge("utilization.network", util.Utilization, nil)
			s.ddGauge("utilization.warm", util.WarmUtilization, nil)
			s.ddGauge("utilization.token_budget", util.TokenBudgetUtilization, nil)
			s.ddGauge("utilization.bottleneck", util.BottleneckUtilization, nil)
			s.ddGauge("capacity.tps", util.CapacityTPS, nil)
			s.ddGauge("capacity.demand_concurrency", util.DemandConcurrency, nil)
			s.ddGauge("capacity.serving_capacity", util.ServingCapacity, nil)
			s.ddGauge("capacity.spill_arrival_rate", util.SpillArrivalRate, nil)
			for _, m := range util.Models {
				s.ddGauge("utilization.model", m.Utilization, []string{"model:" + m.Model})
			}
		}
	}
}

// readCacheJanitorInterval is how often expired readCache entries are reclaimed.
// Get already skips expired entries, so this only frees memory — but without it
// high-cardinality keys (e.g. the per-account "account-earnings:" entries) are
// written and never re-read, so they linger forever and the cache grows unbounded.
const readCacheJanitorInterval = time.Minute

// StartReadCacheJanitor periodically purges expired entries from the read cache
// so it can't grow unbounded. Call as a goroutine; stops when ctx is cancelled.
func (s *Server) StartReadCacheJanitor(ctx context.Context) {
	s.runReadCacheJanitor(ctx, readCacheJanitorInterval)
}

// runReadCacheJanitor is StartReadCacheJanitor with an injectable interval (tests).
func (s *Server) runReadCacheJanitor(ctx context.Context, interval time.Duration) {
	if s.readCache == nil {
		return
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.readCache.PurgeExpired()
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
	return s.corsMiddleware(s.recoverMiddleware(s.loggingMiddleware(s.bodyLimitMiddleware(s.mux))))
}

// bodyLimitMiddleware caps every request body at maxRequestBodyBytes so an
// unbounded POST can't OOM the coordinator (the trusted TEE component).
// Per-handler MaxBytesReader caps (tighter) layer on top. The provider
// WebSocket upgrade is exempt: it hijacks the connection and reads framed
// messages (bounded separately), not r.Body.
func (s *Server) bodyLimitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil && r.URL.Path != "/ws/provider" {
			r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
		}
		next.ServeHTTP(w, r)
	})
}

// decodeCappedJSON JSON-decodes the request body under a hard size cap, writing
// a 413 (too large) or 400 (bad JSON) and returning false on failure. For small
// unauthenticated control-plane endpoints that must not buffer an unbounded body.
func decodeCappedJSON(w http.ResponseWriter, r *http.Request, maxBytes int64, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			writeJSON(w, http.StatusRequestEntityTooLarge,
				errorResponse("invalid_request_error", "request body too large"))
			return false
		}
		writeJSON(w, http.StatusBadRequest,
			errorResponse("invalid_request_error", "invalid JSON"))
		return false
	}
	return true
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
			stampAuth(r, "privy", true)
			next(w, r.WithContext(ctx))
			return
		}

		// Accept admin key (admin endpoints handle further authorization in-handler).
		if s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
			ctx := context.WithValue(r.Context(), ctxKeyConsumer, "admin")
			stampAuth(r, "admin", false)
			next(w, r.WithContext(ctx))
			return
		}

		// Fall back to API key auth.
		// Check cache first to skip DB on repeat requests with the same key.
		var keyRec *store.APIKey
		authKind := "apikey_cache"
		if cached, ok := s.lookupAPIKeyCache(token); ok {
			keyRec = cached.key
		} else {
			authKind = "apikey_db"
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
		authDBRead := authKind == "apikey_db"
		if accountID != "" {
			authDBRead = true
			if user, err := s.store.GetUserByAccountID(accountID); err == nil {
				ctx = context.WithValue(ctx, auth.CtxKeyUser, user)
			}
		} else {
			accountID = store.LegacyAccountID(token)
		}

		ctx = context.WithValue(ctx, ctxKeyConsumer, accountID)
		ctx = context.WithValue(ctx, ctxKeyAPIKey, keyRec)
		stampAuth(r, authKind, authDBRead)
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
			stampRateLimit(r)
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
		stampRateLimit(r)
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
	"/v1/stats":          true,
	"/v1/network/series": true,
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
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, "+metadataDetailsHeader)
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
		// Profiler correlation id is ALWAYS coordinator-minted (the client-supplied
		// X-Request-ID above is echoed and logged but never persisted).
		if s.profilerEnabled() {
			meta := &requestMeta{coordID: reqID, start: start}
			if r.Header.Get("X-Request-ID") != "" {
				meta.coordID = newRequestID()
			}
			ctx = context.WithValue(ctx, requestMetaKey{}, meta)
		}
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
