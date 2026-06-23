package registry

import (
	"math"
	"strings"
	"time"
)

// Prefill-fallback recalibration — the coordinator-side, ship-now mitigation for
// the live 41% long-prompt ttft_429 over-shed. No provider release required.
//
// Root cause (docs/reports/2026-06-22-live-prefill-tps-check.md): no provider in
// the fleet reports a usable observed_prefill_tps (0 of 313 warm slots, 100% of
// clean warm routing decisions resolved prefill to exactly the fallback). So
// resolvePrefillTPS falls back to resolvedPrefillTPS(p) =
// sqrt(MemoryBandwidthGBs) × prefillToDecodeRatio ≈ 280 tok/s p50 — ~23× below
// the measured real prefill (empirical idle p50 6,523 tok/s, p90 17,707 tok/s,
// recovered EXACTLY by inverting the stored ttft_ms). That pessimistic estimate
// makes the TTFT gate reject every prompt above ~550 tokens.
//
// This file adds a data-derived fallback (defaultPrefillFallbackTPS ≈ the
// measured p50) that REPLACES the sqrt(bandwidth)×ratio estimate when no
// measurement exists, gated behind EIGENINFERENCE_PREFILL_FALLBACK_MODE so it can
// be staged shadow→enforce. It is orthogonal to the durable provider-side
// measurement fix (which makes observed_prefill_tps non-zero): once a provider
// reports a real value, resolvePrefillTPS prefers that measured value and this
// fallback is never consulted. It also raises maxPrefillTPS above the measured
// p90 so a correctly-measured value is not discarded at ingest or capped at
// routing time.

// PrefillFallbackMode selects how the recalibrated prefill fallback is applied.
type PrefillFallbackMode int

const (
	// PrefillFallbackOff is the default: resolvePrefillTPS returns the legacy
	// sqrt(bandwidth)×ratio fallback, byte-for-byte the pre-recalibration value.
	PrefillFallbackOff PrefillFallbackMode = iota
	// PrefillFallbackShadow leaves live routing on the legacy fallback but lets
	// the API layer emit routing.prefill_fallback{would_admit|would_shed} so the
	// projected ttft_429 recovery can be measured before enforcing.
	PrefillFallbackShadow
	// PrefillFallbackEnforce applies the recalibrated fallback to live routing:
	// resolvePrefillTPS uses max(static, prefillFallbackTPS) when no measured
	// prefill exists, capped at maxPrefillTPS.
	PrefillFallbackEnforce
)

func (m PrefillFallbackMode) String() string {
	switch m {
	case PrefillFallbackShadow:
		return "shadow"
	case PrefillFallbackEnforce:
		return "enforce"
	default:
		return "off"
	}
}

// ParsePrefillFallbackMode maps an env string to a mode. Anything unrecognized
// (including empty) is OFF — the safe, behavior-neutral default.
func ParsePrefillFallbackMode(s string) PrefillFallbackMode {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "shadow":
		return PrefillFallbackShadow
	case "enforce":
		return PrefillFallbackEnforce
	default:
		return PrefillFallbackOff
	}
}

// defaultPrefillFallbackTPS is the data-derived prefill fallback (tok/s): the
// measured empirical idle prefill p50 = 6,523 tok/s (lower bound, recovered by
// inverting the router's own stored ttft_ms on prompts ≥800 tok;
// docs/reports/2026-06-22-live-prefill-tps-check.md). Rounded to 6500. It is
// CONSERVATIVE on purpose: the regression slope implies a true asymptotic rate of
// 7,500–10,500 tok/s, so anchoring on the p50 will not over-admit, while still
// being ~23× the broken ~280 tok/s estimate that drives the 41% over-shed. Prefill
// on Apple-Silicon MLX is a parallel/compute-bound pass, so a flat anchor (not the
// bandwidth-scaled decode proxy) is the honest representation of the fleet-aggregate
// data; tune per-deployment via EIGENINFERENCE_PREFILL_FALLBACK_TPS.
const defaultPrefillFallbackTPS = 6500.0

// defaultMaxPrefillTPS is the sanity ceiling (tok/s) on resolved/ingested prefill
// rates. Raised from the legacy 5000 to sit comfortably above the measured p90
// (17,707 tok/s) so (a) the recalibrated fallback (6500) is not capped back down
// and (b) a correctly-measured cold-prefill value from a fixed provider is neither
// zeroed at ingest (clampBackendCapacity) nor capped at routing time
// (resolvePrefillTPS) — while still rejecting the "billions of tok/s" overflow a
// collapsed admitted→first-token window produces. Tunable for rollback via
// EIGENINFERENCE_MAX_PREFILL_TPS.
const defaultMaxPrefillTPS = 20000.0

// All three are configured once at startup (from main.go env wiring) and read-only
// on routing/ingest paths thereafter, mirroring prefillToDecodeRatio /
// ttftAdmissionMode.
var (
	prefillFallbackMode = PrefillFallbackOff
	prefillFallbackTPS  = defaultPrefillFallbackTPS
	// maxPrefillTPS is the prefill sanity ceiling shared by clampBackendCapacity
	// (ingest zeroing of out-of-range observed_prefill_tps), the registration
	// prefill_tps clamp, and resolvePrefillTPS (routing cap). Declared here rather
	// than in registry.go's const block so the prefill ceiling lives next to the
	// fallback it must clear.
	maxPrefillTPS = defaultMaxPrefillTPS
)

// SetPrefillFallbackMode sets the recalibration mode. Must be called before
// serving starts (read-only on routing paths thereafter).
func SetPrefillFallbackMode(mode PrefillFallbackMode) { prefillFallbackMode = mode }

// PrefillFallbackModeValue returns the configured recalibration mode.
func PrefillFallbackModeValue() PrefillFallbackMode { return prefillFallbackMode }

// SetPrefillFallbackTPS overrides the data-derived fallback (tok/s). Values <= 0
// are ignored. Must be called before serving starts.
func SetPrefillFallbackTPS(tps float64) {
	if tps > 0 {
		prefillFallbackTPS = tps
	}
}

// PrefillFallbackTPS returns the configured prefill fallback (tok/s).
func PrefillFallbackTPS() float64 { return prefillFallbackTPS }

// SetMaxPrefillTPS overrides the prefill sanity ceiling (tok/s). Values <= 0 are
// ignored. Must be called before serving starts.
func SetMaxPrefillTPS(tps float64) {
	if tps > 0 {
		maxPrefillTPS = tps
	}
}

// MaxPrefillTPS returns the configured prefill sanity ceiling (tok/s).
func MaxPrefillTPS() float64 { return maxPrefillTPS }

// prefillTPSForSnapshot resolves the prefill TPS for a snapshot. The measured
// per-slot observed prefill EWMA always wins when present (>0). Otherwise, when
// recalibrate is true and the provider reports BackendCapacity (so its TTFT
// estimate is actually consulted by the gate), the data-derived fallback lifts the
// pessimistic sqrt(bandwidth)×ratio static estimate — never lowering it, so a
// (hypothetical) higher static prefill_tps is preserved. The result is always
// capped at maxPrefillTPS.
func prefillTPSForSnapshot(snap routingSnapshot, recalibrate bool) float64 {
	tps := snap.prefillTPS
	if snap.observedPrefillTPS > 0 {
		tps = snap.observedPrefillTPS
	} else if recalibrate && snap.hasBackendCapacity {
		if prefillFallbackTPS > tps {
			tps = prefillFallbackTPS
		}
	}
	if tps > maxPrefillTPS {
		tps = maxPrefillTPS
	}
	return tps
}

// recalibratedTTFTMsFromSnapshot is the TTFT estimate computed with the
// recalibrated prefill fallback FORCED on, regardless of mode. Used only by the
// shadow path to measure the projected admission recovery WITHOUT changing the
// live decision (which, in shadow mode, still runs on the legacy fallback).
func recalibratedTTFTMsFromSnapshot(snap routingSnapshot, reqPromptTokens int) float64 {
	return ttftMsFromSnapshotWithPrefill(snap, reqPromptTokens, prefillTPSForSnapshot(snap, true))
}

// estimatedRecalibratedTTFTFromSnapshot mirrors estimatedTTFTFromSnapshot but with
// the recalibrated prefill fallback forced on. Returns 0 for an invalid estimate
// (no BackendCapacity, NaN/Inf), matching the live preflight contract.
func estimatedRecalibratedTTFTFromSnapshot(snap routingSnapshot, reqPromptTokens int) time.Duration {
	ttftMs := recalibratedTTFTMsFromSnapshot(snap, reqPromptTokens)
	if ttftMs <= 0 || math.IsNaN(ttftMs) || math.IsInf(ttftMs, 0) {
		return 0
	}
	return time.Duration(ttftMs * float64(time.Millisecond))
}
