package main

import (
	"errors"
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func configureAccounts(srv *api.Server, reg *registry.Registry, st store.Store, cfg *config.AppConfig, logger *slog.Logger) {
	billingCfg := cfg.BillingConfig
	ledger := payments.NewLedger(st)
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
}
