package app

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	startup "github.com/eigeninference/d-inference/coordinator/internal/startup"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/profilesign"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func configureBillingAndTrust(ctx context.Context, cfg config.AppConfig, srv *api.Server, reg *registry.Registry, st store.Store, ledger *payments.Ledger, logger *slog.Logger) {
	billingCfg := cfg.BillingConfig
	billingSvc := billing.NewService(st, ledger, logger, billingCfg)
	srv.SetBilling(billingSvc)

	// Provider base rewards (off unless EIGENINFERENCE_BASE_REWARDS=true).
	if brc := cfg.ServerConfig.BaseRewards; brc.Enabled {
		brCfg := baserewards.DefaultConfig()
		brCfg.Enabled = true
		brCfg.ReductionK = brc.ReductionK
		brCfg.PoolBudgetMicroUSD = brc.FloorPoolB
		brCfg.MinUptimeFrac = brc.MinUptimeFrac
		brCfg.PerAccountCapFrac = brc.AccountCapFrac
		srv.SetBaseRewards(baserewards.NewEngine(st, reg, brCfg, logger))
		logger.Info("base rewards enabled",
			"reduction_k", brCfg.ReductionK,
			"pool_micro_usd", brCfg.PoolBudgetMicroUSD,
			"min_uptime", brCfg.MinUptimeFrac)
	} else {
		logger.Info("base rewards disabled (set EIGENINFERENCE_BASE_REWARDS=true to enable)")
	}

	// Derive the coordinator's long-lived X25519 key.
	if coordKey, err := e2e.DeriveCoordinatorKey(billingCfg.EncryptionMnemonic); err == nil {
		srv.Inference().SetCoordinatorKey(coordKey)
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
		logger.Info("admin accounts configured", "count", len(cfg.AdminEmails))
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
		logger.Info("billing enabled", "methods", names, "referral_share_pct", billingSvc.Referral().SharePercent())
	}

	// Configure MDM client for provider security verification.
	mdmCfg := cfg.MDMConfig
	if mdmCfg.URL != "" {
		mdmClient := mdm.NewClient(mdmCfg.URL, mdmCfg.APIKey, logger)

		mdmClient.SetOnMDA(srv.Trust().ApplyLateMDA)

		// Register callbacks for responses that arrive after the synchronous wait.
		// The server accepts them only for the exact current scheduler command
		// binding after the connection's phase-1 challenge has settled.
		mdmClient.SetOnLateSecurityInfo(srv.Trust().ApplyLateSecurityInfo)

		srv.SetMDMClient(mdmClient)
		srv.StartMDMScheduler()
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
		deadline, err := startup.ParseAPNsEnforceAfter()
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

	// Seed durable trust reuse only after the fsync-backed hard-untrust journal is
	// available and replayed. A pending or malformed journal must block startup;
	// accepting providers before replay could resurrect a stale hardware row.
	if err := srv.SeedTrustReuseCache(ctx); err != nil {
		logger.Error("refusing to start: trust-reuse revocation journal is not safe",
			"health_reason", "trust_reuse_revocation_journal_unavailable",
			"error", err,
		)
		os.Exit(1)
	}

}
