package main

import (
	"log/slog"
	"os"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func configureAdmission(srv *api.Server, logger *slog.Logger) {
	// Routing: TTFT admission ceiling mode. Default is a SOFT routing preference
	// (serve the best-available provider when one passes every routing/capacity
	// gate). Set this to restore the legacy HARD 429 when the best estimated TTFT
	// exceeds the pinned request-local model deadline. The estimate's prefill
	// term is not provider-measured, so the hard gate over-rejected serveable
	// requests.
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

	// Routing (Phase-0 TTFT-contention, shadow + measurement slice). All three
	// knobs are behavior-neutral at their defaults:
	//
	//   - EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA (float, default 0): coefficient of
	//     the occupancy term added to the TTFT estimate (ttftMsFromSnapshot). 0
	//     leaves the estimate — and therefore the routing cost's TTFTMs, the
	//     candidate-loop ceiling, and the preflight bestTTFT — byte-for-byte the
	//     pre-Phase-0 value. Reuses the occupancy the snapshot already tracks
	//     (max(pendingForModel, backend_running+backend_waiting)); herd-aware.
	//   - EIGENINFERENCE_TTFT_DEADLINE_BASE_MS (float, default 10000): the
	//     ordinary-model SLA base the shadow evaluator gates against. The
	//     standard OpenRouter SLA is ~10s+1ms/token; exact-model policy can only
	//     tighten that base. The instance-owned live first-content deadline
	//     configured above is independent. Used ONLY by the shadow evaluator.
	//   - EIGENINFERENCE_TTFT_ADMISSION_MODE (off|shadow|enforce, default off):
	//     off => no evaluation; shadow/enforce => compute would_shed +
	//     would_redirect_to_idle and emit routing.ttft_admission /
	//     routing.ttft_spread WITHOUT changing the routing decision. enforce is
	//     reserved for a future step that would actually shed; it currently
	//     behaves like shadow.
	if v := os.Getenv("EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA"); v != "" {
		if alpha, ok := validateTTFTOccupancyAlpha(v); ok {
			registry.SetTTFTOccupancyAlpha(alpha)
			logger.Info("TTFT occupancy term configured via EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA", "alpha", alpha, "behavior_neutral", alpha == 0)
		} else {
			logger.Warn("invalid or out-of-range EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA; keeping default 0 (term off)",
				"value", v, "max", maxTTFTOccupancyAlpha)
		}
	}
	if v := os.Getenv("EIGENINFERENCE_TTFT_DEADLINE_BASE_MS"); v != "" {
		if base, ok := validateTTFTDeadlineBaseMs(v); ok {
			registry.SetTTFTDeadlineBaseMs(base)
			logger.Info("TTFT shadow deadline base configured via EIGENINFERENCE_TTFT_DEADLINE_BASE_MS", "base_ms", base)
		} else {
			logger.Warn("invalid or out-of-range EIGENINFERENCE_TTFT_DEADLINE_BASE_MS; keeping default ~10s",
				"value", v, "min_ms", minTTFTDeadlineBaseMs, "max_ms", maxTTFTDeadlineBaseMs)
		}
	}
	if v := os.Getenv("EIGENINFERENCE_TTFT_ADMISSION_MODE"); v != "" {
		mode := registry.ParseTTFTAdmissionMode(v)
		registry.SetTTFTAdmissionMode(mode)
		if mode == registry.TTFTAdmissionOff {
			logger.Info("TTFT admission shadow evaluation OFF (EIGENINFERENCE_TTFT_ADMISSION_MODE)", "value", v)
		} else {
			logger.Warn("TTFT admission shadow evaluation ENABLED (measurement only — no decision change)",
				"mode", mode.String(), "deadline_base_ms", registry.TTFTDeadlineBaseMs(), "occupancy_alpha", registry.TTFTOccupancyAlpha())
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

	// Routing-scan concurrency limit (2026-09-01 congestion collapse: a fresh
	// full fleet scan per dispatch attempt × retry-amplified inbound saturated
	// every coordinator CPU). Default runtime.NumCPU() (min 2); override via
	// EIGENINFERENCE_ROUTING_CONCURRENCY. Requests that cannot get a scan slot
	// within their remaining first-content budget shed as capacity-shaped 429s.
	routingConcurrency := api.DefaultRoutingConcurrency()
	if v := os.Getenv("EIGENINFERENCE_ROUTING_CONCURRENCY"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 2 {
			routingConcurrency = n
			srv.SetRoutingConcurrency(n)
		} else {
			logger.Warn("invalid EIGENINFERENCE_ROUTING_CONCURRENCY (need an integer >= 2); using default", "value", v, "default", routingConcurrency)
		}
	}
	logger.Info("routing-scan concurrency limit", "max_concurrent_scans", routingConcurrency)

	// Smart early-429 admission gate. ON by default: a request whose
	// (prompt+max_tokens) cannot fit the model context window or any provider's
	// structural token budget is rejected with an uptime-neutral 429 at preflight
	// instead of being admitted and 5xx'ing on the provider. Only an explicit
	// parseable EIGENINFERENCE_SERVABILITY_GATE=false disables it (resolved live
	// in servabilityGateEnabled). The always-on dispatch-exhausted
	// reclassification of a provider token-budget 5xx → 429 is independent.
	if v := os.Getenv("EIGENINFERENCE_SERVABILITY_GATE"); v != "" {
		if on, err := strconv.ParseBool(v); err == nil && on {
			srv.SetServabilityGate(true)
			logger.Info("smart servability gate ENABLED via EIGENINFERENCE_SERVABILITY_GATE (unservable long prompts → early 429)")
		} else if err == nil && !on {
			logger.Info("smart servability gate DISABLED via EIGENINFERENCE_SERVABILITY_GATE=false")
		} else if err != nil {
			logger.Warn("invalid EIGENINFERENCE_SERVABILITY_GATE; gate defaults ON", "value", v)
		}
	} else {
		logger.Info("smart servability gate ENABLED (default; set EIGENINFERENCE_SERVABILITY_GATE=false to disable)")
	}

	// C1 kill switch: deterministic provider client-4xx (400/413/422/415) returns
	// ONCE instead of failing over up to maxDispatchAttempts. Stop is ON by default;
	// set EIGENINFERENCE_DISABLE_CLIENT_ERROR_STOP=true to restore pre-fix failover.
	if v := os.Getenv("EIGENINFERENCE_DISABLE_CLIENT_ERROR_STOP"); v != "" {
		if on, err := strconv.ParseBool(v); err == nil && on {
			srv.SetDisableClientErrorStop(true)
			logger.Warn("client-error dispatch stop DISABLED via EIGENINFERENCE_DISABLE_CLIENT_ERROR_STOP — deterministic provider 4xx will fail over up to maxDispatchAttempts")
		} else if err != nil {
			logger.Warn("invalid EIGENINFERENCE_DISABLE_CLIENT_ERROR_STOP; stop stays enabled", "value", v)
		}
	}

	// Per-family prompt-token estimate calibration for the servability context
	// check (the len/4 routing estimate undercounts dense content). Default
	// {gpt-oss:1.3}; override with "family:factor,..." e.g. "gpt-oss:1.3,gemma:1.15".
	if v := os.Getenv("EIGENINFERENCE_PROMPT_CALIBRATION"); v != "" {
		if n := api.SetPromptContextCalibrationFromEnv(v); n > 0 {
			logger.Info("prompt-token context calibration overridden", "pairs", n, "value", v)
		} else {
			logger.Warn("invalid EIGENINFERENCE_PROMPT_CALIBRATION; using default", "value", v)
		}
	}
}
