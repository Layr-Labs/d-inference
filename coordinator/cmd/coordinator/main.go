// Command coordinator runs the Darkbloom coordinator control plane.
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
// Configuration (environment variables):
//
//	EIGENINFERENCE_PORT         - HTTP listen port (default: "8080")
//	EIGENINFERENCE_ADMIN_KEY    - Pre-seeded API key for bootstrapping
//	EIGENINFERENCE_DATABASE_URL - PostgreSQL connection string (omit for in-memory store)
//
// Graceful shutdown: The coordinator handles SIGINT/SIGTERM, stops the
// eviction loop, and drains active connections with a 15-second deadline.
package main

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"strconv"

	"github.com/eigeninference/coordinator/internal/api"
	"github.com/eigeninference/coordinator/internal/attestation"
	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/mdm"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

func main() {
	// Structured logging.
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))
	slog.SetDefault(logger)

	// Configuration from environment.
	port := envOr("EIGENINFERENCE_PORT", "8080")
	adminKey := os.Getenv("EIGENINFERENCE_ADMIN_KEY")

	if adminKey == "" {
		logger.Warn("EIGENINFERENCE_ADMIN_KEY is not set — no pre-seeded API key available")
	}

	// Create core components.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var st store.Store
	if dbURL := os.Getenv("EIGENINFERENCE_DATABASE_URL"); dbURL != "" {
		pgStore, err := store.NewPostgres(ctx, dbURL)
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
		st = store.NewMemory(adminKey)
		logger.Info("using in-memory store")
	}

	// Seed the model catalog if empty (first startup or fresh DB).
	seedModelCatalog(st, logger)

	reg := registry.New(logger)

	// Set minimum trust level for routing. Default: hardware (production).
	// Set EIGENINFERENCE_MIN_TRUST=none or EIGENINFERENCE_MIN_TRUST=self_signed for testing.
	if minTrust := os.Getenv("EIGENINFERENCE_MIN_TRUST"); minTrust != "" {
		reg.MinTrustLevel = registry.TrustLevel(minTrust)
		logger.Info("minimum trust level override", "level", minTrust)
	}

	srv := api.NewServer(reg, st, logger)
	srv.SetAdminKey(adminKey)

	// Sync the model catalog to the registry so providers and consumers
	// are filtered against the admin-managed whitelist.
	srv.SyncModelCatalog()

	// Console URL — frontend for device auth verification links.
	if consoleURL := os.Getenv("EIGENINFERENCE_CONSOLE_URL"); consoleURL != "" {
		srv.SetConsoleURL(consoleURL)
		logger.Info("console URL configured", "url", consoleURL)
	}

	// Base URL — this coordinator's public origin (e.g. https://api.dev.darkbloom.dev).
	// Templated into the embedded install.sh at serve time so a single binary
	// can serve both prod and dev. Falls back to the request's Host header if unset.
	if baseURL := os.Getenv("EIGENINFERENCE_BASE_URL"); baseURL != "" {
		srv.SetBaseURL(baseURL)
		logger.Info("base URL configured", "url", baseURL)
	}

	// R2 CDN URLs — substituted into install.sh at serve time. Each env has its
	// own R2 bucket (prod: d-inf-app; dev: d-inf-app-dev). Dev can set only the
	// primary CDN and the site-packages one defaults to the same bucket.
	if cdn := os.Getenv("EIGENINFERENCE_R2_CDN_URL"); cdn != "" {
		srv.SetR2CDNURL(cdn)
		logger.Info("R2 CDN URL configured", "url", cdn)
	}
	if cdn := os.Getenv("EIGENINFERENCE_R2_SITE_PACKAGES_CDN_URL"); cdn != "" {
		srv.SetR2SitePackagesCDNURL(cdn)
		logger.Info("R2 site-packages CDN URL configured", "url", cdn)
	}

	// Scoped release key — GitHub Actions uses this to register new releases.
	// Separate from admin key: can only POST /v1/releases, nothing else.
	if releaseKey := os.Getenv("EIGENINFERENCE_RELEASE_KEY"); releaseKey != "" {
		srv.SetReleaseKey(releaseKey)
		logger.Info("release key configured")
	}

	// Sync known-good provider hashes from active releases in the store.
	// Falls back to env vars if no releases exist yet.
	srv.SyncBinaryHashes()
	srv.SyncRuntimeManifest()
	if hashList := os.Getenv("EIGENINFERENCE_KNOWN_BINARY_HASHES"); hashList != "" {
		// Env var hashes are additive — merge with any from releases.
		hashes := strings.Split(hashList, ",")
		srv.AddKnownBinaryHashes(hashes)
		logger.Info("additional binary hashes from env var", "count", len(hashes))
	}

	// Load runtime manifest from environment variables.
	// When configured, providers whose runtime hashes don't match are excluded from
	// routing (but not disconnected) and receive feedback about mismatches.
	{
		pythonHashes := os.Getenv("EIGENINFERENCE_KNOWN_PYTHON_HASHES")
		runtimeHashes := os.Getenv("EIGENINFERENCE_KNOWN_RUNTIME_HASHES")
		templateHashes := os.Getenv("EIGENINFERENCE_KNOWN_TEMPLATE_HASHES") // format: name=hash,name=hash

		if pythonHashes != "" || runtimeHashes != "" || templateHashes != "" {
			manifest := &api.RuntimeManifest{
				PythonHashes:   make(map[string]bool),
				RuntimeHashes:  make(map[string]bool),
				TemplateHashes: make(map[string]string),
			}
			if pythonHashes != "" {
				for _, h := range strings.Split(pythonHashes, ",") {
					h = strings.TrimSpace(h)
					if h != "" {
						manifest.PythonHashes[h] = true
					}
				}
			}
			if runtimeHashes != "" {
				for _, h := range strings.Split(runtimeHashes, ",") {
					h = strings.TrimSpace(h)
					if h != "" {
						manifest.RuntimeHashes[h] = true
					}
				}
			}
			if templateHashes != "" {
				for _, pair := range strings.Split(templateHashes, ",") {
					parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
					if len(parts) == 2 {
						manifest.TemplateHashes[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
					}
				}
			}
			srv.SetRuntimeManifest(manifest)
			logger.Info("runtime manifest configured",
				"python_hashes", len(manifest.PythonHashes),
				"runtime_hashes", len(manifest.RuntimeHashes),
				"template_hashes", len(manifest.TemplateHashes),
			)
		}
	}

	// Configure billing service.
	//
	// Day-1 launch: Solana USDC (via Privy embedded wallets) + Referrals.
	// Users sign their own USDC transfers in the frontend, then submit the
	// tx signature here. We verify on-chain and credit their balance.
	// Stripe is wired but not activated until we flip the env vars on.
	billingCfg := billing.Config{
		// Solana — primary payment rail
		SolanaRPCURL:             os.Getenv("EIGENINFERENCE_SOLANA_RPC_URL"),
		SolanaUSDCMint:           envOr("EIGENINFERENCE_SOLANA_USDC_MINT", "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"), // mainnet USDC
		SolanaCoordinatorAddress: os.Getenv("EIGENINFERENCE_SOLANA_COORDINATOR_ADDRESS"),                                   // fallback if no mnemonic (deposit-only, no withdrawals)
		SolanaMnemonic:           envOr("MNEMONIC", os.Getenv("EIGENINFERENCE_SOLANA_MNEMONIC")),                           // BIP39 mnemonic → derive keypair + deposit address (legacy: EIGENINFERENCE_SOLANA_MNEMONIC)

		// Stripe — present but not activated day-1 (set env vars to enable)
		StripeSecretKey:     os.Getenv("EIGENINFERENCE_STRIPE_SECRET_KEY"),
		StripeWebhookSecret: os.Getenv("EIGENINFERENCE_STRIPE_WEBHOOK_SECRET"),
		StripeSuccessURL:    os.Getenv("EIGENINFERENCE_STRIPE_SUCCESS_URL"),
		StripeCancelURL:     os.Getenv("EIGENINFERENCE_STRIPE_CANCEL_URL"),

		// Stripe Connect Express — bank/card payouts. Reuses StripeSecretKey
		// for API auth; the Connect webhook endpoint has its own signing
		// secret. Return/refresh URLs are where Stripe sends users back to
		// after the hosted onboarding flow.
		StripeConnectWebhookSecret:   os.Getenv("EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET"),
		StripeConnectPlatformCountry: envOr("EIGENINFERENCE_STRIPE_CONNECT_COUNTRY", "US"),
		StripeConnectReturnURL:       os.Getenv("EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL"),
		StripeConnectRefreshURL:      os.Getenv("EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL"),
	}

	// Mock billing mode — skips on-chain verification, auto-credits test balance.
	if os.Getenv("EIGENINFERENCE_BILLING_MOCK") == "true" {
		billingCfg.MockMode = true
		logger.Warn("BILLING MOCK MODE ENABLED — deposits skip on-chain verification")
	}

	// Parse referral share percentage
	if refShareStr := os.Getenv("EIGENINFERENCE_REFERRAL_SHARE_PCT"); refShareStr != "" {
		if v, err := strconv.ParseInt(refShareStr, 10, 64); err == nil {
			billingCfg.ReferralSharePercent = v
		}
	}

	ledger := payments.NewLedger(st)
	billingSvc := billing.NewService(st, ledger, logger, billingCfg)
	srv.SetBilling(billingSvc)

	// Configure admin accounts.
	if adminEmails := os.Getenv("EIGENINFERENCE_ADMIN_EMAILS"); adminEmails != "" {
		emails := strings.Split(adminEmails, ",")
		srv.SetAdminEmails(emails)
		logger.Info("admin accounts configured", "emails", emails)
	}

	// Configure Privy authentication.
	if privyAppID := os.Getenv("EIGENINFERENCE_PRIVY_APP_ID"); privyAppID != "" {
		privyVerificationKey := os.Getenv("EIGENINFERENCE_PRIVY_VERIFICATION_KEY")
		// Support reading PEM from a file (systemd can't handle multiline env vars).
		if keyFile := os.Getenv("EIGENINFERENCE_PRIVY_VERIFICATION_KEY_FILE"); keyFile != "" {
			if data, err := os.ReadFile(keyFile); err == nil {
				privyVerificationKey = string(data)
			}
		}
		privyAppSecret := os.Getenv("EIGENINFERENCE_PRIVY_APP_SECRET")

		privyAuth, err := auth.NewPrivyAuth(auth.Config{
			AppID:           privyAppID,
			AppSecret:       privyAppSecret,
			VerificationKey: privyVerificationKey,
		}, st, logger)
		if err != nil {
			logger.Error("failed to initialize Privy auth", "error", err)
		} else {
			srv.SetPrivyAuth(privyAuth)
			logger.Info("Privy authentication enabled", "app_id", privyAppID)
		}
	}

	// Log which billing methods are active
	methods := billingSvc.SupportedMethods()
	if len(methods) > 0 {
		var names []string
		for _, m := range methods {
			names = append(names, string(m.Method))
		}
		logger.Info("billing enabled", "methods", names, "referral_share_pct", billingCfg.ReferralSharePercent)
	}

	// Configure MDM client for provider security verification.
	// When set, the coordinator independently verifies SIP/SecureBoot via MicroMDM
	// rather than trusting the provider's self-reported attestation.
	if mdmURL := os.Getenv("EIGENINFERENCE_MDM_URL"); mdmURL != "" {
		mdmKey := os.Getenv("EIGENINFERENCE_MDM_API_KEY")
		if mdmKey == "" {
			mdmKey = "eigeninference-micromdm-api" // default
		}
		mdmClient := mdm.NewClient(mdmURL, mdmKey, logger)

		// Register callback for late-arriving MDA certs — stores them
		// on the provider so users can verify via the attestation API.
		mdmClient.SetOnMDA(func(udid string, certChain [][]byte) {
			// Find the provider with this UDID and store the cert chain
			reg.ForEachProvider(func(p *registry.Provider) {
				if p.AttestationResult == nil {
					return
				}
				// Match by checking if this provider's MDM UDID matches
				// (UDID is set during MDM verification)
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

		srv.SetMDMClient(mdmClient)
		logger.Info("MDM verification enabled", "url", mdmURL)
	}

	// Configure step-ca root CA for ACME client cert verification.
	// When providers present a TLS client cert issued by step-ca via
	// device-attest-01, the coordinator verifies the chain and grants
	// hardware trust (Apple-attested SE key binding).
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
					// Try to load intermediate too
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

	// Start background eviction of stale providers.
	reg.StartEvictionLoop(ctx, 90*time.Second)

	// HTTP server with graceful shutdown.
	httpServer := &http.Server{
		Addr:         ":" + port,
		Handler:      srv.Handler(),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 0, // SSE streaming requires no write timeout
		IdleTimeout:  120 * time.Second,
	}

	// Start listening.
	go func() {
		logger.Info("coordinator starting", "port", port, "admin_key_set", adminKey != "")
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

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// seedModelCatalog ensures all hardcoded models exist in the catalog.
// On first startup it populates everything; on subsequent starts it adds
// any new models that were added to the code but not yet in the DB.
func seedModelCatalog(st store.Store, logger *slog.Logger) {
	existing := st.ListSupportedModels()
	existingIDs := make(map[string]bool, len(existing))
	for _, m := range existing {
		existingIDs[m.ID] = true
	}

	models := []store.SupportedModel{
		// --- Transcription (speech-to-text) ---
		{ID: "CohereLabs/cohere-transcribe-03-2026", S3Name: "cohere-transcribe-03-2026", DisplayName: "Cohere Transcribe", ModelType: "transcription", SizeGB: 4.2, Architecture: "2B conformer", Description: "Best-in-class STT", MinRAMGB: 8, Active: true},

		// --- Image generation (Draw Things + Metal FlashAttention) ---
		{ID: "flux_2_klein_4b_q8p.ckpt", S3Name: "flux-klein-4b-q8", DisplayName: "FLUX.2 Klein 4B", ModelType: "image", SizeGB: 8.1, Architecture: "4B diffusion", Description: "Fast image gen", MinRAMGB: 16, Active: true},
		{ID: "flux_2_klein_9b_q8p.ckpt", S3Name: "flux-klein-9b-q8", DisplayName: "FLUX.2 Klein 9B", ModelType: "image", SizeGB: 17.4, Architecture: "9B diffusion + Qwen 8B encoder", Description: "Higher quality image gen", MinRAMGB: 32, Active: true},

		// --- Text generation (8-bit quantization) ---
		{ID: "qwen3.5-27b-claude-opus-8bit", S3Name: "qwen35-27b-claude-opus-8bit", DisplayName: "Qwen3.5 27B Claude Opus Distilled", ModelType: "text", SizeGB: 27.0, Architecture: "27B dense, Claude Opus distilled", Description: "Frontier quality reasoning", MinRAMGB: 36, Active: true},
		{ID: "mlx-community/Trinity-Mini-8bit", S3Name: "Trinity-Mini-8bit", DisplayName: "Trinity Mini", ModelType: "text", SizeGB: 26.0, Architecture: "27B Adaptive MoE", Description: "Fast agentic inference", MinRAMGB: 48, Active: true},
		{ID: "mlx-community/gemma-4-26b-a4b-it-8bit", S3Name: "gemma-4-26b-a4b-it-8bit", DisplayName: "Gemma 4 26B", ModelType: "text", SizeGB: 28.0, Architecture: "26B MoE, 4B active", Description: "Fast multimodal MoE", MinRAMGB: 36, Active: true},
		{ID: "mlx-community/Qwen3.5-122B-A10B-8bit", S3Name: "Qwen3.5-122B-A10B-8bit", DisplayName: "Qwen3.5 122B", ModelType: "text", SizeGB: 122.0, Architecture: "122B MoE, 10B active", Description: "Best quality", MinRAMGB: 128, Active: true},
		{ID: "mlx-community/MiniMax-M2.5-8bit", S3Name: "MiniMax-M2.5-8bit", DisplayName: "MiniMax M2.5", ModelType: "text", SizeGB: 243.0, Architecture: "239B MoE, 11B active", Description: "SOTA coding, 100 tok/s", MinRAMGB: 256, Active: true},
	}

	added := 0
	for i := range models {
		if existingIDs[models[i].ID] {
			continue
		}
		if err := st.SetSupportedModel(&models[i]); err != nil {
			logger.Warn("failed to seed model", "id", models[i].ID, "error", err)
		} else {
			added++
		}
	}
	if added > 0 {
		logger.Info("new models added to catalog", "added", added, "total", len(existing)+added)
	} else {
		logger.Info("model catalog loaded", "count", len(existing))
	}
}
