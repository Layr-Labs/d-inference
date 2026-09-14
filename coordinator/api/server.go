package api

import (
	"crypto/subtle"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/accountfleet"
	"github.com/eigeninference/d-inference/coordinator/api/catalog"
	"github.com/eigeninference/d-inference/coordinator/api/network"
	"github.com/eigeninference/d-inference/coordinator/api/readiness"
	"github.com/eigeninference/d-inference/coordinator/api/requestauth"
	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/providerframe"
	"github.com/eigeninference/d-inference/coordinator/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/codeidentity"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/mdmscheduler"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/releasepolicy"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"
)

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
var LatestProviderVersion = "0.9.2"

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
	catalogOnce                   sync.Once
	modelCatalog                  *catalog.Controller // shared listing and alias mutation owner
	challengeInterval             time.Duration       // 0 means use DefaultChallengeInterval
	skipChallenge                 bool                // if true, skip attestation challenges entirely (testing only)
	allowDuplicateProviderSerials bool                // in-process multi-provider testbed only
	privyAuth                     *auth.PrivyAuth     // Privy JWT authentication (nil if not configured)
	adminEmails                   map[string]bool     // emails that have admin access
	adminKey                      string              // EIGENINFERENCE_ADMIN_KEY for admin endpoints
	mdmClient                     *mdm.Client         // MicroMDM client for provider security verification
	mdmScheduler                  *mdmscheduler.Scheduler
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
	codeIdentity                  *codeidentity.Manager // per-device code proof, nonce and APNs budget lifecycle
	trustReuse                    *trustreuse.Manager   // durable device evidence, revocation, replay and continuity

	// One readiness owner is shared by HTTP ingress and graceful shutdown.
	readinessOnce sync.Once
	readiness     *readiness.Controller

	// Release policy owns the binary allowlist, policy generations and runtime manifest.
	releasePolicyOnce sync.Once
	releasePolicy     *releasepolicy.Manager

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

	// settlements parks billing records for requests whose consumer disconnected
	// mid-stream, so a late provider terminal can settle them (or the reservation
	// is refunded on grace expiry). See settlement.go.
	settlements *settlement.Holder
	// settleGrace overrides defaultTerminalSettleGrace (tests set it small).
	settleGrace time.Duration
	// zombieCanceller throttles cancels for chunks on abandoned streams. See zombie_stream.go.
	attemptTracker *attempt.Tracker

	// dispatchController owns shared scan admission, hedge feedback and route latency.
	dispatchOnce       sync.Once
	dispatchController *dispatch.Controller

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

	// geoResolver resolves provider and consumer request locations from IP
	// addresses or trusted reverse-proxy headers. Nil when GeoIP is not configured.
	geoResolver providerGeoResolver

	// coordinatorKey is the long-lived X25519 keypair used to receive sealed
	// requests from senders. Set via SetCoordinatorKey. nil disables the
	// /v1/encryption-key endpoint and the sealed-request middleware.
	coordinatorKey *e2e.CoordinatorKey

	// One frame owner holds the private chunk-key cache and ingress counter.
	providerFrameOnce    sync.Once
	providerFrameService *providerframe.Service

	// metrics is the in-process metrics registry exposed via /v1/admin/metrics
	// and used by internal counters/histograms. Never nil.
	metrics *Metrics

	// readCache memoizes pre-serialized JSON for read-heavy aggregation
	// endpoints (stats, leaderboard, model catalog, etc.). TTLs are
	// per-key. Never nil.
	readCache *ttlCache
	// accountFleet owns the provider dashboard and account earnings flights.
	accountFleet *accountfleet.Controller
	// networkViews owns public aggregation and its background refresh state.
	networkViews *network.Controller

	// emitter writes coordinator-side telemetry events (panics, handler
	// failures, attestation failures, etc.). Set via SetEmitter; nil before
	// main.go wires it up.
	emitter *telemetry.Emitter

	// dd is the Datadog integration client for DogStatsD metrics and
	// Logs API event forwarding. Nil when DD is not configured.
	dd          *datadog.Client
	queueGauges queueGaugeState

	// requestAuth owns shared credential authentication and key-cache state.
	requestAuth *requestauth.Authenticator

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
	serviceReservations *settlement.ServiceHolds

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
	profiler        *profiler
	requestOutcomes *requestOutcomeSink

	// mediaResolver fetches remote http(s) image_url/video_url links into
	// inline base64 data: URIs before the request body is E2E-encrypted to a
	// provider, so consumers can pass links instead of pre-encoding media
	// client-side (media_resolve.go). The coordinator is the single SSRF
	// chokepoint; the provider still only ever sees data: URIs. Set by
	// NewServer from env; nil (e.g. a &Server{} built directly in tests)
	// behaves as disabled and falls back to the legacy pre-dispatch rejection.
	mediaResolver *mediafetch.Resolver
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
		firstContentDeadlineBase = dispatch.DefaultFirstContentDeadlineBase
	}

	s := &Server{
		registry:                 reg,
		store:                    st,
		ledger:                   payments.NewLedger(st),
		logger:                   logger,
		mux:                      http.NewServeMux(),
		metrics:                  NewMetrics(),
		readCache:                newTTLCache(),
		geoResolver:              newProviderGeoResolverFromEnv(logger),
		requestAuth:              requestauth.New(),
		mdmSchedulerConfig:       cfg.MDMScheduler,
		settlements:              settlement.NewHolder(),
		attemptTracker:           attempt.NewTracker(),
		serviceReservations:      settlement.NewServiceHolds(st, cfg.ServiceReservations),
		routeTelemetry:           newTelemetrySink(logger, defaultTelemetrySinkCapacity, defaultTelemetrySinkWorkers),
		mediaResolver:            mediafetch.NewResolver(mediaFetchCfg, logger),
		firstContentDeadlineBase: firstContentDeadlineBase,
	}
	s.initializeInferenceDispatch(dispatch.Config{RoutingConcurrency: dispatch.DefaultRoutingConcurrency(), HedgeGovernor: true})

	// Registry write-lock wait, by call site. This is the acceptance metric
	// for taking the recorders off the request path: today the wait is only
	// inferable from goroutine dumps.
	reg.SetLockWaitObserver(func(site string, wait time.Duration) {
		s.ddHistogram("registry.mu.write_wait_ms", float64(wait.Microseconds())/1000, []string{"site:" + site})
	})
	s.releasePolicyOwner().SetRuntimeManifest(&RuntimeManifest{})
	s.codeIdentity = codeidentity.New(codeidentity.DefaultConfig(), s.codeIdentityDependencies())
	s.trustReuse = trustreuse.New(trustreuse.Config{
		DurableTrustReuse:     cfg.DurableTrustReuse,
		TrustReuseJournalPath: cfg.TrustReuseJournalPath,
	}, s.trustReuseDependencies())
	reg.SetRuntimeCapabilitiesPromotedHook(s.handleRuntimeCapabilitiesPromoted)
	// The per-identity gate locks that replaced the request-path registry
	// write lock (registry/gate_state.go) report any acquisition wait above
	// 1 ms here, tagged by recorder site, so the new locks stay observable.
	reg.SetGateWaitObserver(func(site string, wait time.Duration) {
		s.ddHistogram("registry.gate.wait_ms", float64(wait.Microseconds())/1000, []string{"site:" + site})
	})
	s.profiler = newProfilerFromEnv(s)
	s.requestOutcomes = newRequestOutcomeSink(s, defaultTelemetrySinkCapacity)
	s.registerDefaultGauges()
	s.networkViews = s.newNetworkViews()
	s.accountFleet = s.newAccountFleet()
	s.routes()

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

// Close releases background resources owned by the Server.
func (s *Server) Close() {
	// Graceful-shutdown continuity sweep: stop the periodic coverage loop,
	// then persist the exact shutdown instant for every covered provider so a
	// short deploy reconnects into the continuity fast-skip on the next
	// coordinator instead of a fleet-wide live MDM herd. A crash skips this —
	// the last periodic write stands and the gap is over-estimated (fail-safe).
	s.trustReuse.StopCoverage()
	s.trustReuse.FinalCoverageSweep()
	s.sweepCodeAttestCoverage()
	s.trustReuse.StopReplay()
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
		if !s.routeTelemetry.CloseAndWait(telemetrySinkShutdownFlush) && s.logger != nil {
			s.logger.Warn("routing telemetry sink did not finish flushing before the shutdown deadline",
				"deadline", telemetrySinkShutdownFlush,
				"dropped_total", s.routeTelemetry.DroppedTotal(),
			)
		}
	}
	s.trustReuse.ReleaseAuthority()
	if s.requestOutcomes != nil {
		s.requestOutcomes.Close()
	}
	if s.profiler != nil {
		s.profiler.Close()
	}
}

// SetMinProviderVersion sets the minimum provider version for routing.
func (s *Server) SetMinProviderVersion(v string) {
	s.minProviderVersion = strings.TrimSpace(v)
}

// SetProfileSigner configures the CMS signing identity used to sign the
// enrollment .mobileconfig served by /v1/enroll. When unset (nil), profiles are
// served unsigned (the historical behaviour).
func (s *Server) SetProfileSigner(signer *profilesign.Signer) {
	s.profileSigner = signer
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

// SetMDMClient configures the MicroMDM client for provider verification.
// When set, providers are verified against MDM on registration.
func (s *Server) SetMDMClient(client *mdm.Client) {
	s.mdmClient = client
	if client != nil && s.mdmScheduler == nil {
		s.mdmScheduler = mdmscheduler.New(s.mdmSchedulerConfig, s.mdmSchedulerDependencies())
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
	if s.codeIdentity == nil {
		s.codeIdentity = codeidentity.New(codeidentity.DefaultConfig(), s.codeIdentityDependencies())
	}
	s.codeIdentity.SetAttestor(a)
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

// SetReleaseKey configures the scoped release key for GitHub Actions.
func (s *Server) SetReleaseKey(key string) {
	s.releaseKey = key
}

// SetCoordinatorKey installs the X25519 keypair the coordinator publishes
// for sender-to-coordinator request encryption. Pass nil to disable.
func (s *Server) SetCoordinatorKey(k *e2e.CoordinatorKey) {
	s.coordinatorKey = k
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
