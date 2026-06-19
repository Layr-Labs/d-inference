// Command coordinator runs the Darkbloom (EigenInference) coordinator control plane.
//
// The coordinator is the central routing and trust layer in the Darkbloom network.
// It accepts provider WebSocket connections, verifies their Secure Enclave
// attestations, and routes OpenAI-compatible HTTP requests from consumers
// to appropriate providers based on model availability and trust level.
//
// Deployment: The coordinator runs in a GCP Confidential VM (AMD SEV-SNP)
// with hardware-encrypted memory. Consumer traffic arrives over HTTPS/TLS.
// The coordinator can read requests for routing purposes but never logs
// prompt content.
//
// Configuration is defined per-package and composed into config.AppConfig.
// See coordinator/config/ for the full schema.
//
// Graceful shutdown: The coordinator handles SIGINT/SIGTERM, stops the
// eviction loop, and drains active connections with a 15-second deadline.
package main

import (
	"context"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry"

	ddtracer "gopkg.in/DataDog/dd-trace-go.v1/ddtrace/tracer"
)

// defaultPrefillKeepaliveInterval is the on-by-default cadence for SSE prefill
// keepalives. Chosen to sit below typical fetch timeouts while keeping the
// early-commit blast radius to genuinely long prefills; tune via
// EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL (0 disables).
const defaultPrefillKeepaliveInterval = 10 * time.Second

func main() {
	// Structured JSON logging. When Datadog is active, we wrap the handler
	// with trace context injection so logs correlate with APM traces.
	var slogHandler slog.Handler = slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})
	if os.Getenv("DD_API_KEY") != "" || os.Getenv("DD_AGENT_HOST") != "" {
		slogHandler = datadog.NewTraceHandler(slogHandler)
	}
	logger := slog.New(slogHandler)
	slog.SetDefault(logger)

	// Read all configuration from environment variables.
	cfg := config.ReadAppConfig()
	if err := cfg.Check(); err != nil {
		logger.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	adminKey := cfg.AdminKey
	if adminKey == "" {
		logger.Warn("EIGENINFERENCE_ADMIN_KEY is not set — no pre-seeded API key available")
	}

	// Create core components.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var st store.Store
	if cfg.StoreConfig.DatabaseURL != "" {
		pgStore, err := store.NewPostgres(ctx, cfg.StoreConfig)
		if err != nil {
			logger.Error("failed to connect to PostgreSQL", "error", err)
			os.Exit(1)
		}
		defer pgStore.Close()
		st = pgStore
		logger.Info("using PostgreSQL store")

		// If an admin key is set, seed it in the database.
		if adminKey != "" {
			if err := pgStore.SeedKey(adminKey); err != nil {
				logger.Warn("failed to seed admin key (may already exist)", "error", err)
			}
		}
	} else {
		if !cfg.StoreConfig.AllowMemoryStore {
			logger.Error("EIGENINFERENCE_DATABASE_URL is not set and EIGENINFERENCE_ALLOW_MEMORY_STORE is not \"true\" — refusing to start with non-durable store")
			os.Exit(1)
		}

		memStore := store.NewMemory(store.Config{AdminKey: adminKey})
		st = memStore
		logger.Warn("using in-memory store — billing state will not survive restart (set EIGENINFERENCE_DATABASE_URL for production)")

		pruneInterval := 15 * time.Minute
		pruneMax := store.DefaultPruneMaxEntries
		saferun.Go(logger, "memory_store_pruner", func() {
			ticker := time.NewTicker(pruneInterval)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					memStore.Prune(pruneMax)
				}
			}
		})
	}

	// Reconcile provider sessions left open by a previous coordinator process
	// (durable uptime history). Best-effort + time-bounded — neither an error nor
	// a slow/unresponsive DB must block startup. Only sessions whose last
	// heartbeat is older than the staleness fence are closed, so a blue-green
	// cutover over the shared DB does NOT truncate sessions still live (and being
	// touched every heartbeat) on the old instance — only genuinely-orphaned rows
	// from a dead prior process age past the fence and get closed.
	func() {
		rctx, rcancel := context.WithTimeout(ctx, 10*time.Second)
		defer rcancel()
		// 3 min comfortably exceeds the 30s heartbeat and 90s eviction window, so
		// any session live on another instance stays fresh; orphans do not.
		staleBefore := time.Now().Add(-3 * time.Minute)
		if n, err := st.CloseOpenProviderSessions(rctx, staleBefore); err != nil {
			logger.Warn("failed to reconcile open provider sessions", "error", err)
		} else if n > 0 {
			logger.Info("reconciled orphaned provider sessions", "closed", n)
		}
	}()

	reg := registry.New(logger)

	// Set minimum trust level for routing.
	if cfg.RegistryCfg.MinTrustLevel != "" {
		reg.MinTrustLevel = registry.TrustLevel(cfg.RegistryCfg.MinTrustLevel)
		logger.Info("minimum trust level override", "level", cfg.RegistryCfg.MinTrustLevel)
	}
	reg.ConfigureCacheAffinity(cfg.RegistryCfg.CacheAffinity)
	cacheAffinityCfg := reg.CacheAffinityConfigSnapshot()
	logger.Info("cache affinity configured", "ttl", cacheAffinityCfg.TTL.String(), "bonus_ms", cacheAffinityCfg.BonusMs, "enabled", cacheAffinityCfg.BonusMs > 0)
	stopWarmPool := reg.StartWarmPoolController(ctx, cfg.RegistryCfg.WarmPool)
	defer stopWarmPool()
	if cfg.RegistryCfg.WarmPool.Enabled {
		logger.Info("warm-pool controller enabled", "observe_only", cfg.RegistryCfg.WarmPool.ObserveOnly, "interval", cfg.RegistryCfg.WarmPool.Interval.String())
	}

	srv := api.NewServer(reg, st, cfg.ServerConfig, logger)
	// Stop the routing-telemetry sink's worker pool on shutdown. Deferred so it
	// runs after the HTTP server has drained (no in-flight request can still be
	// submitting telemetry); Close is idempotent and never blocks on in-flight
	// writes, so it cannot stall shutdown.
	defer srv.Close()

	// Per-account rate limiter on consumer (inference) endpoints. The default
	// is intentionally generous (20 rps / burst 120) — the fleet token-budget
	// admission is the real capacity ceiling, so this is a fairness/abuse guard.
	if cfg.RateLimitCfg.RPS > 0 {
		rl := ratelimit.New(cfg.RateLimitCfg)
		rl.StartPruner(ctx, logger, func() { saferun.Recover(logger, "ratelimit_pruner") })
		srv.SetRateLimiter(rl)
		logger.Info("per-account rate limiter enabled", "rps", cfg.RateLimitCfg.RPS, "burst", cfg.RateLimitCfg.Burst)
	} else {
		logger.Warn("per-account rate limiter DISABLED (EIGENINFERENCE_RATE_LIMIT_RPS=0)")
	}

	// Stricter per-account limiter on financial endpoints.
	if cfg.FinancialRL.RPS > 0 {
		frl := ratelimit.New(cfg.FinancialRL)
		frl.StartPruner(ctx, logger, func() { saferun.Recover(logger, "financial_ratelimit_pruner") })
		srv.SetFinancialRateLimiter(frl)
		logger.Info("financial-endpoint rate limiter enabled", "rps", cfg.FinancialRL.RPS, "burst", cfg.FinancialRL.Burst)
	} else {
		logger.Warn("financial-endpoint rate limiter DISABLED (EIGENINFERENCE_FINANCIAL_RATE_LIMIT_RPS=0)")
	}

	// Elevated request limiter for trusted service accounts (e.g. OpenRouter),
	// which fan out many end-users behind a single key. Set the service RPS to
	// 0 to drop the per-request ceiling for service accounts.
	//
	// Note: the service role is admin-provisioned only (PUT /v1/admin/users/role,
	// admin-gated) — consumers cannot self-escalate into this tier. Disabling
	// this request limiter does NOT make service traffic unbounded: it remains
	// gated by the per-account token limits (ITPM/OTPM, below), the account's
	// prepaid balance, and the fleet token-budget admission ceiling.
	if cfg.ServiceRL.RPS > 0 {
		srl := ratelimit.New(cfg.ServiceRL)
		srl.StartPruner(ctx, logger, func() { saferun.Recover(logger, "service_ratelimit_pruner") })
		srv.SetServiceRateLimiter(srl)
		logger.Info("service-account rate limiter enabled", "rps", cfg.ServiceRL.RPS, "burst", cfg.ServiceRL.Burst)
	} else {
		logger.Warn("service-account request rate limiter DISABLED — service accounts still bounded by token (ITPM/OTPM) limits, prepaid balance, and fleet admission")
	}

	// Per-account token-per-minute limiters (ITPM/OTPM) — the industry-standard
	// token throttle alongside RPM. Per-minute limits are converted to
	// tokens/second; bursts must be >= the largest single request (>= max
	// context for input, >= max output for output). Set a tier's ITPM and OTPM
	// both to 0 to disable token limiting for that tier.
	consumerTok := cfg.ConsumerTokens
	serviceTok := cfg.ServiceTokens
	var consumerTokenLimiter, serviceTokenLimiter *ratelimit.TokenLimiter
	if consumerTok.InputPerMinute > 0 || consumerTok.OutputPerMinute > 0 {
		consumerTokenLimiter = ratelimit.NewTokenLimiter(consumerTok.InputPerMinute/60, consumerTok.InputBurst, consumerTok.OutputPerMinute/60, consumerTok.OutputBurst)
		consumerTokenLimiter.StartPruner(ctx, logger, func() { saferun.Recover(logger, "consumer_token_ratelimit_pruner") })
		logger.Info("consumer token rate limiter enabled", "itpm", consumerTok.InputPerMinute, "otpm", consumerTok.OutputPerMinute)
	}
	if serviceTok.InputPerMinute > 0 || serviceTok.OutputPerMinute > 0 {
		serviceTokenLimiter = ratelimit.NewTokenLimiter(serviceTok.InputPerMinute/60, serviceTok.InputBurst, serviceTok.OutputPerMinute/60, serviceTok.OutputBurst)
		serviceTokenLimiter.StartPruner(ctx, logger, func() { saferun.Recover(logger, "service_token_ratelimit_pruner") })
		logger.Info("service token rate limiter enabled", "itpm", serviceTok.InputPerMinute, "otpm", serviceTok.OutputPerMinute)
	}
	srv.SetTokenLimiters(consumerTokenLimiter, serviceTokenLimiter)
	if outputAdmission := ratelimit.NewOutputAdmissionEstimator(cfg.OutputAdmission); outputAdmission != nil {
		srv.SetOutputAdmissionEstimator(outputAdmission)
		estCfg := outputAdmission.Config()
		logger.Info("service expected-output token admission enabled", "fraction", estCfg.Fraction, "floor", estCfg.Floor, "ceiling", estCfg.Ceiling)
	}

	// Per-key (variable-rate) limiters for per-key RPM and ITPM/OTPM overrides.
	// Unlike the per-account limiters above, these only act when an individual
	// key sets an override; otherwise the key inherits the account-level limits.
	// They carry no global rate of their own (each call supplies the key's rate).
	keyRPMLimiter := ratelimit.New(ratelimit.Config{RPS: ratelimit.DefaultRPS, Burst: ratelimit.DefaultBurst})
	keyRPMLimiter.StartPruner(ctx, logger, func() { saferun.Recover(logger, "key_rpm_ratelimit_pruner") })
	keyTokenLimiter := ratelimit.NewKeyTokenLimiter()
	keyTokenLimiter.StartPruner(ctx, logger, func() { saferun.Recover(logger, "key_token_ratelimit_pruner") })
	srv.SetKeyLimiters(keyRPMLimiter, keyTokenLimiter)
	logger.Info("per-key rate limiters enabled (RPM + ITPM/OTPM overrides)")

	// Coordinator self-telemetry emitter.
	telemetryEmitter := telemetry.NewEmitter(logger, srv.Metrics(), telemetry.CoordinatorVersion)
	srv.SetEmitter(telemetryEmitter)

	// --- Datadog APM + DogStatsD + Logs API ---
	ddCfg := cfg.DatadogConfig
	if ddCfg.APIKey != "" || os.Getenv("DD_AGENT_HOST") != "" {
		ddtracer.Start(
			ddtracer.WithService(ddCfg.Service),
			ddtracer.WithEnv(ddCfg.Env),
		)
		defer ddtracer.Stop()
		logger.Info("datadog APM tracer started", "service", ddCfg.Service, "env", ddCfg.Env)

		ddClient, err := datadog.NewClient(ddCfg, logger)
		if err != nil {
			logger.Warn("datadog client init failed (continuing without DD)", "error", err)
		} else {
			srv.SetDatadog(ddClient)
			telemetryEmitter.SetDatadog(ddClient)
			defer ddClient.Close()
			logger.Info("datadog integration enabled",
				"statsd_addr", ddCfg.StatsdAddr,
				"logs_api", ddCfg.APIKey != "",
				"site", ddCfg.Site,
			)
		}
	}

	// Sync the model catalog to the registry.
	srv.SyncModelCatalog()

	// Server configuration applied from config.ServerConfig during NewServer().

	// Sync known-good provider hashes from active releases in the store.
	srv.SyncBinaryHashes()
	srv.SyncRuntimeManifest()
	if hashList := os.Getenv("EIGENINFERENCE_KNOWN_BINARY_HASHES"); hashList != "" {
		hashes := strings.Split(hashList, ",")
		srv.AddKnownBinaryHashes(hashes)
		logger.Info("additional binary hashes from env var", "count", len(hashes))
	}
	// v0.6.0: self-reported binaryHash is demoted to drift telemetry by default
	// (APNs code-identity attestation is the real signal). Set this to re-enable
	// the legacy derouting-on-mismatch behavior (rollback only).
	if os.Getenv("EIGENINFERENCE_BINARYHASH_ENFORCE") == "true" {
		srv.SetBinaryHashEnforcement(true)
		logger.Warn("binaryHash enforcement ENABLED via EIGENINFERENCE_BINARYHASH_ENFORCE (legacy; APNs code-identity is the real signal)")
	}

	// Routing: TTFT admission ceiling mode. Default is a SOFT routing preference
	// (serve the best-available provider when one passes every routing/capacity
	// gate). Set this to restore the legacy HARD 429 when the best estimated TTFT
	// exceeds the 5s+1ms/token deadline. The estimate's prefill term is not
	// provider-measured, so the hard gate over-rejected serveable requests.
	if os.Getenv("EIGENINFERENCE_TTFT_HARD_REJECT") == "true" {
		srv.SetTTFTHardReject(true)
		logger.Warn("TTFT hard-reject ENABLED via EIGENINFERENCE_TTFT_HARD_REJECT (legacy 429-on-slow-estimate; soft preference is the default)")
	}

	// Routing: deterministic per-model shed list. These requested aliases/resolved
	// builds return 429 + Retry-After at admission, before rate-limit/billing/routing.
	// Use this for unhealthy models (e.g. Gemma 4) while keeping TTFT hard-reject
	// disabled globally so healthy models like gpt-oss can keep flowing.
	if v := os.Getenv("EIGENINFERENCE_REJECT_MODELS"); v != "" {
		shed := map[string]bool{}
		for _, name := range strings.Split(v, ",") {
			if name = strings.TrimSpace(name); name != "" {
				shed[name] = true
			}
		}
		if len(shed) > 0 {
			srv.SetRejectModels(shed)
			logger.Warn("model shed ENABLED via EIGENINFERENCE_REJECT_MODELS (429 at admission)", "models", v)
		}
	}

	// Routing: decode→prefill ratio fallback, used to estimate prefill TPS when a
	// provider does not report a measured prefill_tps. Defaults to
	// registry.defaultPrefillToDecodeRatio.
	if v := os.Getenv("EIGENINFERENCE_PREFILL_DECODE_RATIO"); v != "" {
		if ratio, err := strconv.ParseFloat(v, 64); err == nil && ratio > 0 {
			registry.SetPrefillToDecodeRatio(ratio)
			logger.Info("prefill/decode ratio override via EIGENINFERENCE_PREFILL_DECODE_RATIO", "ratio", ratio)
		} else {
			logger.Warn("invalid EIGENINFERENCE_PREFILL_DECODE_RATIO; ignoring", "value", v)
		}
	}

	// Routing: long-prompt fastest-tier preference. Very long prompts
	// have a long prefill window that drives pre-first-token client cancellations
	// (client_gone). When EIGENINFERENCE_LONG_PROMPT_TOKENS is set, the scheduler
	// biases requests whose estimated prompt is at/above that count toward the
	// fastest-prefill (== fastest chip tier) warm provider. Unset/<=0 keeps the
	// routing cost behavior-neutral. SOFT ranking bias only — it never adds a hard
	// TTFT 429. The optional EIGENINFERENCE_LONG_PROMPT_PREFILL_WEIGHT (default
	// 2.0; >1 amplifies, <1 clamps to neutral) tunes how strong the bias is.
	if v := os.Getenv("EIGENINFERENCE_LONG_PROMPT_TOKENS"); v != "" {
		if tokens, err := strconv.Atoi(v); err == nil && tokens > 0 {
			srv.SetLongPromptThreshold(tokens)
			weight := registry.LongPromptPrefillWeight() // sensible default unless overridden
			if wv := os.Getenv("EIGENINFERENCE_LONG_PROMPT_PREFILL_WEIGHT"); wv != "" {
				if w, werr := strconv.ParseFloat(wv, 64); werr == nil {
					// Pass any parsed float to the setter, which clamps values
					// below 1.0 to the neutral 1.0 — so an operator can set 0 or
					// 0.5 to disable the bias (as the comment above documents)
					// instead of having it silently fall back to the strong
					// default. Read the effective (clamped) value back for the log.
					srv.SetLongPromptPrefillWeight(w)
					weight = registry.LongPromptPrefillWeight()
				} else {
					logger.Warn("invalid EIGENINFERENCE_LONG_PROMPT_PREFILL_WEIGHT; using default", "value", wv, "default", weight)
				}
			}
			logger.Info("long-prompt fastest-tier routing preference ENABLED via EIGENINFERENCE_LONG_PROMPT_TOKENS",
				"threshold_tokens", tokens, "prefill_weight", weight)
		} else {
			logger.Warn("invalid EIGENINFERENCE_LONG_PROMPT_TOKENS; ignoring (preference stays off)", "value", v)
		}
	}

	// Routing: per-request sustained-decode floor (tokens/sec). The quality bar is
	// ON BY DEFAULT (15 tok/s) so the scheduler won't pack a provider into a
	// degraded stream; it softly prefers providers that keep a newly admitted
	// request at >= this rate (never rejects on its own — falls back to
	// best-available). Set EIGENINFERENCE_MIN_DECODE_TPS to override; 0 disables.
	minDecodeTPS := 15.0 // default quality bar
	if v := os.Getenv("EIGENINFERENCE_MIN_DECODE_TPS"); v != "" {
		if tps, err := strconv.ParseFloat(v, 64); err == nil && tps >= 0 {
			minDecodeTPS = tps
		} else {
			logger.Warn("invalid EIGENINFERENCE_MIN_DECODE_TPS; using default", "value", v, "default", minDecodeTPS)
		}
	}
	srv.SetMinDecodeTPS(minDecodeTPS)
	logger.Info("per-request decode floor (quality bar)", "min_decode_tps", minDecodeTPS)

	// Smart early-429 admission gate. OFF by default (behavior-neutral).
	// When enabled, a request whose (prompt+max_tokens) cannot fit the model
	// context window or any provider's structural token budget is rejected with an
	// uptime-neutral 429 at preflight instead of being admitted and 5xx'ing on the
	// provider. The always-on dispatch-exhausted reclassification of a provider
	// token-budget 5xx → 429 is independent of this flag.
	if v := os.Getenv("EIGENINFERENCE_SERVABILITY_GATE"); v != "" {
		if on, err := strconv.ParseBool(v); err == nil && on {
			srv.SetServabilityGate(true)
			logger.Info("smart servability gate ENABLED via EIGENINFERENCE_SERVABILITY_GATE (unservable long prompts → early 429)")
		} else if err != nil {
			logger.Warn("invalid EIGENINFERENCE_SERVABILITY_GATE; gate stays off", "value", v)
		}
	}

	// SSE keepalives during long prefill. ON by default at a 10s cadence so a long
	// prefill never leaves the consumer connection idle long enough for OpenRouter's
	// fetch timeout to fire and fail us over mid-prefill. The first keepalive fires
	// one interval in, so a STREAMING request that produces its first token quickly
	// keeps clean deferred-commit / invisible-failover — only genuinely long
	// prefills commit HTTP 200 early and emit ": keepalive" comments. Override the
	// cadence (or set 0 to disable) via EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL (a
	// Go duration); tune it below OpenRouter's fetch timeout.
	prefillKeepalive := defaultPrefillKeepaliveInterval
	if v := os.Getenv("EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d >= 0 {
			prefillKeepalive = d
		} else {
			logger.Warn("invalid EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL; using default (want a Go duration like 5s, or 0 to disable)", "value", v, "default", defaultPrefillKeepaliveInterval.String())
		}
	}
	srv.SetPrefillKeepaliveInterval(prefillKeepalive)
	if prefillKeepalive > 0 {
		logger.Info("prefill SSE keepalives enabled", "interval", prefillKeepalive.String())
	} else {
		logger.Info("prefill SSE keepalives disabled")
	}

	// Load runtime template manifest from environment variable (optional override).
	// When configured, providers whose template hashes don't match are excluded from
	// routing (but not disconnected) and receive feedback about mismatches.
	// Python/runtime hashes are deprecated — only template hashes (e.g. mlx_metallib) are checked.
	if templateHashes := os.Getenv("EIGENINFERENCE_KNOWN_TEMPLATE_HASHES"); templateHashes != "" {
		manifest := &api.RuntimeManifest{
			PythonHashes:   make(map[string]bool),
			RuntimeHashes:  make(map[string]bool),
			TemplateHashes: make(map[string]string),
		}
		for _, pair := range strings.Split(templateHashes, ",") {
			parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
			if len(parts) == 2 {
				manifest.TemplateHashes[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
			}
		}
		srv.SetRuntimeManifest(manifest)
		logger.Info("runtime manifest configured from env",
			"template_hashes", len(manifest.TemplateHashes),
		)
	}

	billingCfg := cfg.BillingConfig
	ledger := payments.NewLedger(st)
	billingSvc := billing.NewService(st, ledger, logger, billingCfg)
	srv.SetBilling(billingSvc)

	// Derive the coordinator's long-lived X25519 key.
	if coordKey, err := e2e.DeriveCoordinatorKey(billingCfg.EncryptionMnemonic); err == nil {
		srv.SetCoordinatorKey(coordKey)
		logger.Info("sender→coordinator encryption enabled",
			"kid", coordKey.KID,
			"hkdf_info", e2e.CoordinatorKeyHKDFInfo,
		)
	} else if !errors.Is(err, e2e.ErrNoMnemonic) {
		logger.Error("failed to derive coordinator encryption key", "error", err)
	} else {
		logger.Warn("sender→coordinator encryption disabled — no mnemonic configured")
	}

	// Configure admin accounts.
	if len(cfg.AdminEmails) > 0 {
		srv.SetAdminEmails(cfg.AdminEmails)
		logger.Info("admin accounts configured", "emails", cfg.AdminEmails)
	}

	// Configure Privy authentication.
	authCfg := cfg.AuthConfig
	if authCfg.AppID != "" {
		privyAuth, err := auth.NewPrivyAuth(authCfg, st, logger)
		if err != nil {
			logger.Error("failed to initialize Privy auth", "error", err)
		} else {
			srv.SetPrivyAuth(privyAuth)
			logger.Info("Privy authentication enabled", "app_id", authCfg.AppID)
		}
	}

	// Log which billing methods are active.
	methods := billingSvc.SupportedMethods()
	if len(methods) > 0 {
		var names []string
		for _, m := range methods {
			names = append(names, string(m.Method))
		}
		logger.Info("billing enabled", "methods", names, "referral_share_pct", billingCfg.ReferralSharePercent)
	}

	// Configure MDM client for provider security verification.
	mdmCfg := cfg.MDMConfig
	if mdmCfg.URL != "" {
		mdmClient := mdm.NewClient(mdmCfg.URL, mdmCfg.APIKey, logger)

		mdmClient.SetOnMDA(func(udid string, certChain [][]byte) {
			// Parse + verify the Apple cert chain once (not per provider).
			mdaResult, err := attestation.VerifyMDADeviceAttestation(certChain)
			if err != nil {
				logger.Error("late MDA cert parse error", "udid", udid, "error", err)
				return
			}
			if !mdaResult.Valid {
				return
			}
			// Attach the proof only to a connection that currently holds hardware
			// trust, atomically (trust check + writes under one lock). A late
			// DevicePropertiesAttestation can arrive after the device reconnected as
			// self_signed (RestoreProviderState caps it); attaching MDA to a
			// self_signed provider is the drift this fix removes — and a separate
			// check-then-write would be a TOCTOU. MDA is re-earned live once hardware
			// is re-granted this connection.
			reg.ForEachProvider(func(p *registry.Provider) {
				if p.SetMDAProofIfHardware(certChain, mdaResult) {
					logger.Info("late MDA cert stored on provider",
						"provider_id", p.ID,
						"serial", mdaResult.DeviceSerial,
						"udid", mdaResult.DeviceUDID,
						"os_version", mdaResult.OSVersion,
					)
				}
			})
		})

		// Register callback for late-arriving SecurityInfo responses. When APN
		// delivery is slow (device sleeping, Power Nap cycle), the synchronous 90s
		// wait may time out but the webhook arrives later. The Server method
		// retroactively upgrades the matching self_signed provider — mirroring the
		// synchronous success path (status guard + trust_status notification) so the
		// two paths can't drift.
		mdmClient.SetOnLateSecurityInfo(srv.ApplyLateSecurityInfo)

		srv.SetMDMClient(mdmClient)
		// Optional shared secret for the MicroMDM webhook. Defense-in-depth on
		// top of the mandatory solicited-command (CommandUUID) gate: configure
		// MicroMDM's command-webhook-url with ?token=<secret> and set this to
		// the same value to reject any caller that lacks it.
		if webhookSecret := os.Getenv("EIGENINFERENCE_MDM_WEBHOOK_SECRET"); webhookSecret != "" {
			srv.SetMDMWebhookSecret(webhookSecret)
			logger.Info("MDM webhook shared-secret auth enabled")
		} else {
			// The solicited-command (CommandUUID) gate still protects the
			// webhook, but the shared secret is the recommended extra layer.
			// Warn so a misconfigured deployment is visible at startup.
			logger.Warn("EIGENINFERENCE_MDM_WEBHOOK_SECRET not set — MDM webhook relies solely on the CommandUUID gate; set it + keep MicroMDM bound to localhost for defense in depth")
		}
		logger.Info("MDM verification enabled", "url", mdmCfg.URL)
	}

	// Configure step-ca root CA for ACME client cert verification.
	if stepCARoot := os.Getenv("EIGENINFERENCE_STEP_CA_ROOT"); stepCARoot != "" {
		rootPEM, err := os.ReadFile(stepCARoot)
		if err != nil {
			logger.Error("failed to read step-ca root CA", "path", stepCARoot, "error", err)
		} else {
			block, _ := pem.Decode(rootPEM)
			if block != nil {
				rootCert, err := x509.ParseCertificate(block.Bytes)
				if err != nil {
					logger.Error("failed to parse step-ca root CA", "error", err)
				} else {
					var intCert *x509.Certificate
					stepCAInt := os.Getenv("EIGENINFERENCE_STEP_CA_INTERMEDIATE")
					if stepCAInt != "" {
						intPEM, err := os.ReadFile(stepCAInt)
						if err == nil {
							intBlock, _ := pem.Decode(intPEM)
							if intBlock != nil {
								intCert, _ = x509.ParseCertificate(intBlock.Bytes)
							}
						}
					}
					srv.SetStepCACerts(rootCert, intCert)
					logger.Info("step-ca ACME client cert verification enabled", "root", stepCARoot)
				}
			}
		}
	} else {
		// ACME is the no-live-command leg of the OR-trust model: a provider that
		// presents a valid, bound device-attest-01 mTLS client cert earns hardware
		// trust without any MDM SecurityInfo round-trip. Without the step-ca root
		// that leg is dormant, so every provider must earn hardware trust via the
		// live MDM SecurityInfo path (subject to APNs delivery). Surface the
		// dormancy at startup so activation can be planned + validated.
		logger.Warn("ACME device-cert verification disabled — EIGENINFERENCE_STEP_CA_ROOT not set; providers earn hardware trust via MDM SecurityInfo only")
	}

	// Optional profile signing: when a code-signing identity (e.g. Developer ID
	// Application .p12) is supplied via PROFILE_SIGNING_P12_B64/_PATH (+ _PASSWORD),
	// CMS-sign the /v1/enroll .mobileconfig. Misconfig degrades to unsigned.
	if signer := profilesign.LoadFromEnv(logger); signer != nil {
		srv.SetProfileSigner(signer)
	} else {
		logger.Info("configuration-profile signing not configured — serving unsigned enrollment profiles")
	}

	// Optional APNs code-identity attestation (v0.6.0). When the APNs auth key
	// (.p8) + key/team IDs are supplied, the coordinator pushes an encrypted
	// code-identity challenge to each provider over its WebSocket. Configuring the
	// attestor is SAFE on its own: enforcement (derouting un-attested providers)
	// only begins once APNS_ENFORCE_AFTER (RFC3339) has passed, so the fleet has a
	// grace window to update to 0.6.0 and attest. Absent config leaves it disabled.
	if attestor := loadAPNsAttestor(logger); attestor != nil {
		srv.SetCodeAttestor(attestor)
		// W5 Fix 2 (2b): seed the code-identity reuse cache from the store (and
		// wire write-through) so a blue-green deploy / restart doesn't wipe it and
		// re-push the whole fleet against Apple's ~3/hour/device budget. Durable in
		// prod (Postgres store; see the store selection above); a no-op only under
		// the in-memory store fallback.
		srv.SeedCodeAttestCache(ctx)
		deadline, err := parseAPNsEnforceAfter()
		if err != nil {
			// A non-empty but malformed APNS_ENFORCE_AFTER is an operator error on a
			// security-critical knob; falling back to grace would silently keep
			// un-attested providers routable forever. Fail startup so a typo'd
			// deadline is caught at deploy, not discovered after a security gap.
			logger.Error("refusing to start: APNS_ENFORCE_AFTER is set but invalid (fix it, or unset it for grace mode)",
				"value", os.Getenv("APNS_ENFORCE_AFTER"), "error", err)
			os.Exit(1)
		}
		srv.SetCodeAttestationDeadline(deadline)
		switch {
		case deadline.IsZero():
			logger.Info("APNs code-identity attestation configured in GRACE mode — providers are challenged and measured, but un-attested providers still route (set APNS_ENFORCE_AFTER to begin enforcement)")
		case time.Now().Before(deadline):
			logger.Info("APNs code-identity attestation configured — GRACE until the enforcement deadline, then mandatory",
				"enforce_after", deadline.Format(time.RFC3339))
		default:
			logger.Info("APNs code-identity attestation ENFORCED — un-attested providers are not routed",
				"enforce_after", deadline.Format(time.RFC3339))
		}
	} else {
		logger.Info("APNs code-identity attestation not configured — providers route without code-identity proof")
	}

	// DAR-326 Phase 0: seed the provider trust-reuse cache from the store (and wire
	// write-through + the hard-untrust invalidation hook). This lets a planned
	// coordinator restart / blue-green swap skip a fleet-wide live MDM SecurityInfo
	// + APNs re-verification herd: a reconnecting, recently-fully-verified provider
	// is granted hardware from its record once a fresh live SE challenge re-proves
	// identity + posture. Durable in prod (Postgres store; see the store selection
	// above); a no-op only under the in-memory store fallback. Independent of the
	// APNs attestor — MDM verification runs whenever an MDM client is configured.
	srv.SeedTrustReuseCache(ctx)

	// Start background eviction of stale providers.
	reg.StartEvictionLoop(ctx, 90*time.Second)

	// Push gauge values to DogStatsD periodically.
	go srv.StartDDGaugeLoop(ctx)

	// Reclaim expired read-cache entries periodically (bounds memory growth).
	go srv.StartReadCacheJanitor(ctx)

	// Flag any model decoding far below its active-param/hardware class (W8 —
	// auto-detects the gemma-dense decode bug). Spawns its own panic-safe loop.
	srv.StartThroughputAnomalyDetector(ctx)

	// HTTP server with graceful shutdown.
	httpServer := &http.Server{
		Addr:    ":" + cfg.ServerConfig.Port,
		Handler: srv.Handler(),
		// ReadHeaderTimeout bounds the request-header read phase independently of
		// the body, closing the slow-header (Slowloris) DoS window: a client that
		// trickles or never finishes its header block is dropped at 5s instead of
		// tying up a connection/goroutine. Kept shorter than ReadTimeout so header
		// hardening doesn't constrain legitimate (larger) request bodies.
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      0, // SSE streaming requires no write timeout
		IdleTimeout:       120 * time.Second,
		// MaxHeaderBytes caps per-connection header memory at 64 KB (Go's default
		// is 1 MB), bounding what an attacker can force the server to buffer for
		// headers and rejecting abusive oversized-header requests early.
		MaxHeaderBytes: 64 << 10,
	}

	// Start listening.
	go func() {
		logger.Info("coordinator starting", "port", cfg.ServerConfig.Port, "admin_key_set", adminKey != "")
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server failed", "error", err)
			os.Exit(1)
		}
	}()

	// Wait for interrupt signal.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	sig := <-sigCh
	logger.Info("shutting down", "signal", sig.String())

	// Graceful shutdown with a deadline.
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer shutdownCancel()

	cancel() // Stop the eviction loop.

	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		logger.Error("shutdown error", "error", err)
	}

	logger.Info("coordinator stopped")
}

// parseAPNsEnforceAfter reads APNS_ENFORCE_AFTER (RFC3339) — the instant at which
// code-identity attestation becomes mandatory for routing. Empty/unset returns the
// zero time, which keeps the coordinator in grace/observe mode indefinitely (the
// safe default: configuring APNs secrets never deroutes the fleet). A NON-EMPTY but
// malformed value returns an error so the caller fails startup — silently falling
// back to grace there would be a hidden enforcement downgrade on a typo.
func parseAPNsEnforceAfter() (time.Time, error) {
	raw := strings.TrimSpace(os.Getenv("APNS_ENFORCE_AFTER"))
	if raw == "" {
		// Unset is intentional: grace/observe is the safe default. Only a
		// non-empty-but-malformed value is an error (handled below).
		return time.Time{}, nil
	}
	t, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		return time.Time{}, fmt.Errorf("APNS_ENFORCE_AFTER %q is not valid RFC3339: %w", raw, err)
	}
	return t, nil
}

// loadAPNsAttestor builds the production APNs code-identity attestor from the
// environment, or returns nil (feature disabled) when unconfigured. Required:
// APNS_KEY_ID, APNS_TEAM_ID, and the .p8 auth key via APNS_AUTH_KEY_P8_B64
// (base64 of the PEM) or APNS_AUTH_KEY_P8_PATH. Optional: APNS_TOPIC
// (default io.darkbloom.provider), APNS_MODE ("background" default | "alert").
// The .p8 is a secret — inject via KMS, never commit it.
func loadAPNsAttestor(logger *slog.Logger) *apns.APNsPushAttestor {
	keyID := os.Getenv("APNS_KEY_ID")
	teamID := os.Getenv("APNS_TEAM_ID")
	if keyID == "" || teamID == "" {
		return nil
	}

	var pemBytes []byte
	if b64 := os.Getenv("APNS_AUTH_KEY_P8_B64"); b64 != "" {
		dec, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			logger.Error("APNS_AUTH_KEY_P8_B64 is not valid base64 — APNs attestation disabled", "error", err)
			return nil
		}
		pemBytes = dec
	} else if path := os.Getenv("APNS_AUTH_KEY_P8_PATH"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			logger.Error("failed to read APNS_AUTH_KEY_P8_PATH — APNs attestation disabled", "path", path, "error", err)
			return nil
		}
		pemBytes = b
	} else {
		logger.Warn("APNS_KEY_ID/APNS_TEAM_ID set but no .p8 (APNS_AUTH_KEY_P8_B64 or _PATH) — APNs attestation disabled")
		return nil
	}

	topic := os.Getenv("APNS_TOPIC")
	if topic == "" {
		topic = "io.darkbloom.provider"
	}
	mode := apns.ModeBackground
	if os.Getenv("APNS_MODE") == "alert" {
		mode = apns.ModeAlert
	}

	attestor, err := apns.NewAPNsPushAttestor(apns.Config{
		TeamID:     teamID,
		KeyID:      keyID,
		Topic:      topic,
		AuthKeyPEM: pemBytes,
		Mode:       mode,
	})
	if err != nil {
		logger.Error("failed to construct APNs attestor — attestation disabled", "error", err)
		return nil
	}
	return attestor
}
