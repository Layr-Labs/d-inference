package main

import (
	"context"
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

func configureRateLimits(ctx context.Context, srv *api.Server, cfg *config.AppConfig, logger *slog.Logger) {
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
}
