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

	srv := api.NewServer(reg, st, cfg.ServerConfig, logger)

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
			reg.ForEachProvider(func(p *registry.Provider) {
				if p.AttestationResult == nil {
					return
				}
				mdaResult, err := attestation.VerifyMDADeviceAttestation(certChain)
				if err != nil {
					logger.Error("late MDA cert parse error", "udid", udid, "error", err)
					return
				}
				if mdaResult.Valid && (mdaResult.DeviceSerial == p.AttestationResult.SerialNumber) {
					p.MDAVerified = true
					p.MDACertChain = certChain
					p.MDAResult = mdaResult
					logger.Info("late MDA cert stored on provider",
						"provider_id", p.ID,
						"serial", mdaResult.DeviceSerial,
						"udid", mdaResult.DeviceUDID,
						"os_version", mdaResult.OSVersion,
					)
				}
			})
		})

		// Register callback for late-arriving SecurityInfo responses.
		// When APN delivery is slow (device sleeping, Power Nap cycle),
		// the synchronous 90s wait may time out, but the webhook arrives
		// later. This callback retroactively upgrades self_signed providers.
		mdmClient.SetOnLateSecurityInfo(func(udid string, info *mdm.SecurityInfoResponse) {
			if info == nil || !info.SystemIntegrityProtectionEnabled || info.SecureBootLevel != "full" {
				return
			}
			// Collect self_signed provider candidates under the read lock,
			// then do HTTP lookups outside the lock to avoid blocking
			// heartbeats and routing while MicroMDM responds.
			type candidate struct {
				provider *registry.Provider
				serial   string
			}
			var candidates []candidate
			reg.ForEachProvider(func(p *registry.Provider) {
				p.Mu().Lock()
				trust := p.TrustLevel
				serial := ""
				if p.AttestationResult != nil {
					serial = p.AttestationResult.SerialNumber
				}
				p.Mu().Unlock()
				if trust == registry.TrustSelfSigned && serial != "" {
					candidates = append(candidates, candidate{provider: p, serial: serial})
				}
			})
			for _, c := range candidates {
				dev, _ := mdmClient.LookupDevice(c.serial)
				if dev == nil || dev.UDID != udid {
					continue
				}
				c.provider.SetAttested(true, registry.TrustHardware)
				logger.Info("late SecurityInfo arrival — upgraded provider to hardware trust",
					"provider_id", c.provider.ID,
					"serial", c.serial,
					"udid", udid,
				)
				reg.PersistProvider(c.provider)
			}
		})

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

	// Start background eviction of stale providers.
	reg.StartEvictionLoop(ctx, 90*time.Second)

	// Push gauge values to DogStatsD periodically.
	go srv.StartDDGaugeLoop(ctx)

	// Reclaim expired read-cache entries periodically (bounds memory growth).
	go srv.StartReadCacheJanitor(ctx)

	// HTTP server with graceful shutdown.
	httpServer := &http.Server{
		Addr:         ":" + cfg.ServerConfig.Port,
		Handler:      srv.Handler(),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0, // SSE streaming requires no write timeout
		IdleTimeout:  120 * time.Second,
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
