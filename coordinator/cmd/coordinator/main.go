// Command coordinator runs the EigenInference coordinator control plane.
//
// The coordinator is the central routing and trust layer in the EigenInference network.
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

	// Scoped release key — GitHub Actions uses this to register new releases.
	// Separate from admin key: can only POST /v1/releases, nothing else.
	if releaseKey := os.Getenv("EIGENINFERENCE_RELEASE_KEY"); releaseKey != "" {
		srv.SetReleaseKey(releaseKey)
		logger.Info("release key configured")
	}

	// Sync known-good provider binary hashes from active releases in the store.
	// Falls back to EIGENINFERENCE_KNOWN_BINARY_HASHES env var if no releases exist yet.
	srv.SyncBinaryHashes()
	if hashList := os.Getenv("EIGENINFERENCE_KNOWN_BINARY_HASHES"); hashList != "" {
		// Env var hashes are additive — merge with any from releases.
		hashes := strings.Split(hashList, ",")
		srv.AddKnownBinaryHashes(hashes)
		logger.Info("additional binary hashes from env var", "count", len(hashes))
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
		SolanaCoordinatorAddress: os.Getenv("EIGENINFERENCE_SOLANA_COORDINATOR_ADDRESS"),                                   // address that receives USDC
		SolanaPrivateKey:         os.Getenv("EIGENINFERENCE_SOLANA_PRIVATE_KEY"),                                           // hot wallet key for withdrawals

		// Stripe — present but not activated day-1 (set env vars to enable)
		StripeSecretKey:     os.Getenv("EIGENINFERENCE_STRIPE_SECRET_KEY"),
		StripeWebhookSecret: os.Getenv("EIGENINFERENCE_STRIPE_WEBHOOK_SECRET"),
		StripeSuccessURL:    envOr("EIGENINFERENCE_STRIPE_SUCCESS_URL", "https://inference-test.openinnovation.dev/billing/success"),
		StripeCancelURL:     envOr("EIGENINFERENCE_STRIPE_CANCEL_URL", "https://inference-test.openinnovation.dev/billing/cancel"),
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

// seedModelCatalog populates the supported model catalog if it's empty.
// This provides the initial set of models on first startup.
func seedModelCatalog(st store.Store, logger *slog.Logger) {
	existing := st.ListSupportedModels()
	if len(existing) > 0 {
		logger.Info("model catalog loaded", "count", len(existing))
		return
	}

	models := []store.SupportedModel{
		// --- Transcription (speech-to-text) ---
		{ID: "CohereLabs/cohere-transcribe-03-2026", S3Name: "cohere-transcribe-03-2026", DisplayName: "Cohere Transcribe", ModelType: "transcription", SizeGB: 4.2, Architecture: "2B conformer", Description: "Best-in-class STT", MinRAMGB: 8, Active: true},

		// --- Image generation (Draw Things + Metal FlashAttention) ---
		{ID: "flux_2_klein_4b_q8p.ckpt", S3Name: "flux-klein-4b-q8", DisplayName: "FLUX.2 Klein 4B", ModelType: "image", SizeGB: 8.1, Architecture: "4B diffusion", Description: "Fast image gen", MinRAMGB: 16, Active: true},
		{ID: "flux_2_klein_9b_q8p.ckpt", S3Name: "flux-klein-9b-q8", DisplayName: "FLUX.2 Klein 9B", ModelType: "image", SizeGB: 13.0, Architecture: "9B diffusion", Description: "Higher quality image gen", MinRAMGB: 24, Active: true},

		// --- Text generation (8-bit quantization) ---
		{ID: "qwen3.5-27b-claude-opus-8bit", S3Name: "qwen35-27b-claude-opus-8bit", DisplayName: "Qwen3.5 27B Claude Opus Distilled", ModelType: "text", SizeGB: 27.0, Architecture: "27B dense, Claude Opus distilled", Description: "Frontier quality reasoning", MinRAMGB: 36, Active: true},
		{ID: "mlx-community/Trinity-Mini-8bit", S3Name: "Trinity-Mini-8bit", DisplayName: "Trinity Mini", ModelType: "text", SizeGB: 26.0, Architecture: "27B Adaptive MoE", Description: "Fast agentic inference", MinRAMGB: 48, Active: true},
		{ID: "mlx-community/Qwen3.5-122B-A10B-8bit", S3Name: "Qwen3.5-122B-A10B-8bit", DisplayName: "Qwen3.5 122B", ModelType: "text", SizeGB: 122.0, Architecture: "122B MoE, 10B active", Description: "Best quality", MinRAMGB: 128, Active: true},
		{ID: "mlx-community/MiniMax-M2.5-8bit", S3Name: "MiniMax-M2.5-8bit", DisplayName: "MiniMax M2.5", ModelType: "text", SizeGB: 243.0, Architecture: "239B MoE, 11B active", Description: "SOTA coding, 100 tok/s", MinRAMGB: 256, Active: true},
	}

	for i := range models {
		if err := st.SetSupportedModel(&models[i]); err != nil {
			logger.Warn("failed to seed model", "id", models[i].ID, "error", err)
		}
	}
	logger.Info("model catalog seeded", "count", len(models))
}
