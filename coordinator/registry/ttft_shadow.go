package registry

import "strings"

// Phase-0 SLA-aware, occupancy-aware admission — SHADOW + MEASUREMENT slice.
//
// This file holds the configuration and the read-only evaluator for the TTFT
// admission/spread shadow. It deliberately changes NO routing decision: in
// `off` (default) the evaluator is a no-op; in `shadow` (and, for now, `enforce`)
// it computes two signals against the winning candidate and hands them to the
// caller as fields on RoutingDecision, which the API layer emits as metrics.
//
//   - WouldShed: the occupancy-aware TTFT estimate
//     (occupancyAwareTTFTMsFromSnapshot = base + the occupancy term, which is
//     non-zero only when EIGENINFERENCE_TTFT_OCCUPANCY_ALPHA > 0) for the chosen
//     provider exceeds the verified ~10s deadline base (NOT the code's 5s internal
//     budget — gating at 5s over-sheds ~2x per telemetry-db findings §2). The
//     occupancy term is intentionally confined to this shadow estimate so it can
//     never tighten the live HARD_REJECT ceiling fed by ttftMsFromSnapshot.
//   - IdleAlternativeExists: the chosen provider already carries occupying peers
//     while an instantly-usable (loaded, zero-occupancy) provider for the same
//     model was routable — the load-SPREADING failure the data shows (idle loaded
//     boxes coexisted with 100% of the gpt-oss cancels).
//
// The shadow reuses the occupancy the snapshot ALREADY tracks (snapshotOccupancy
// = max(pendingForModel, backend_running+backend_waiting)); it does NOT introduce
// a parallel reservation counter.

// TTFTAdmissionMode selects the Phase-0 admission behavior.
type TTFTAdmissionMode int

const (
	// TTFTAdmissionOff is the default: the evaluator is a no-op and behavior is
	// byte-for-byte the pre-Phase-0 coordinator.
	TTFTAdmissionOff TTFTAdmissionMode = iota
	// TTFTAdmissionShadow computes the would-shed / would-redirect signals and
	// emits metrics, but SERVES exactly as today (no decision change).
	TTFTAdmissionShadow
	// TTFTAdmissionEnforce is reserved for a future step that would actually shed
	// on the signal. In this Phase-0 slice it behaves identically to shadow
	// (evaluate + emit, no decision change) so it can be wired and validated
	// without flipping live behavior.
	TTFTAdmissionEnforce
)

func (m TTFTAdmissionMode) String() string {
	switch m {
	case TTFTAdmissionShadow:
		return "shadow"
	case TTFTAdmissionEnforce:
		return "enforce"
	default:
		return "off"
	}
}

// ParseTTFTAdmissionMode maps an env string to a mode. Anything unrecognized
// (including empty) is OFF — the safe, behavior-neutral default.
func ParseTTFTAdmissionMode(s string) TTFTAdmissionMode {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "shadow":
		return TTFTAdmissionShadow
	case "enforce":
		return TTFTAdmissionEnforce
	default:
		return TTFTAdmissionOff
	}
}

// defaultTTFTDeadlineBaseMs is the verified OpenRouter SLA base. Cancels fit
// `10000 + 1ms·prompt_tokens` at a median ratio of 1.002 (telemetry-db findings
// §2); the coordinator's internal `ttftDeadline` (consumer.go) still uses a 5s
// base, which would over-shed ~2x if used as the gate — so the shadow evaluator
// uses THIS base, decoupled from consumer.go.
const defaultTTFTDeadlineBaseMs = 10000.0

// Both are configured once at startup (from main.go env wiring) and read-only on
// routing paths thereafter, mirroring prefillToDecodeRatio / ttftOccupancyAlpha.
var (
	ttftAdmissionMode  = TTFTAdmissionOff
	ttftDeadlineBaseMs = defaultTTFTDeadlineBaseMs
)

// SetTTFTAdmissionMode sets the Phase-0 admission mode. Must be called before
// serving starts.
func SetTTFTAdmissionMode(mode TTFTAdmissionMode) {
	ttftAdmissionMode = mode
}

// TTFTAdmissionModeValue returns the configured admission mode.
func TTFTAdmissionModeValue() TTFTAdmissionMode {
	return ttftAdmissionMode
}

// SetTTFTDeadlineBaseMs overrides the shadow-evaluation deadline base (ms).
// Values <= 0 are ignored (keep the verified ~10s default). Must be called
// before serving starts.
func SetTTFTDeadlineBaseMs(ms float64) {
	if ms > 0 {
		ttftDeadlineBaseMs = ms
	}
}

// TTFTDeadlineBaseMs returns the configured shadow-evaluation deadline base (ms).
func TTFTDeadlineBaseMs() float64 {
	return ttftDeadlineBaseMs
}

// ttftDeadlineMsForPrompt is the shadow gate's per-request SLA in ms:
// base + 1ms·prompt_tokens, matching the per-token slope of consumer.ttftDeadline
// but with the verified ~10s base instead of 5s. Used ONLY by the shadow
// evaluator — the live consumer.go ttftDeadline path is untouched.
func ttftDeadlineMsForPrompt(promptTokens int) float64 {
	if promptTokens < 0 {
		promptTokens = 0
	}
	return ttftDeadlineBaseMs + float64(promptTokens)
}

// ttftShadowEval is the result of the read-only Phase-0 evaluation. It is copied
// onto RoutingDecision (applyTo) so the API layer can emit metrics without the
// registry importing the telemetry package.
type ttftShadowEval struct {
	Evaluated             bool
	Mode                  string
	WouldShed             bool
	IdleAlternativeExists bool
	EstimateMs            float64
	DeadlineMs            float64
	Occupancy             int
}

func (e ttftShadowEval) applyTo(d *RoutingDecision) {
	if d == nil || !e.Evaluated {
		return
	}
	d.ShadowEvaluated = true
	d.ShadowMode = e.Mode
	d.ShadowWouldShed = e.WouldShed
	d.ShadowIdleAlternativeExists = e.IdleAlternativeExists
	d.ShadowEstimateMs = e.EstimateMs
	d.ShadowDeadlineMs = e.DeadlineMs
	d.ShadowOccupancy = e.Occupancy
}

// evaluateTTFTShadowLocked computes the Phase-0 shadow signals for the winning
// candidate WITHOUT changing the routing decision. Returns the zero value (a
// no-op for applyTo) when the admission mode is off.
//
// Caller holds r.mu and NO provider lock — the peer scan in
// loadedIdleAlternativeExistsLocked snapshots each provider under its own p.mu,
// so taking a provider lock here would risk holding two at once. winner.snapshot
// is the PRE-reserve snapshot, so the winner's occupancy excludes the request
// about to be admitted (the b, not b+1, the new request actually waits behind).
func (r *Registry) evaluateTTFTShadowLocked(model string, pr *PendingRequest, winner *routingCandidate) ttftShadowEval {
	mode := ttftAdmissionMode
	if mode == TTFTAdmissionOff || winner == nil || pr == nil {
		return ttftShadowEval{}
	}
	reqPrompt := pr.EstimatedPromptTokens
	if reqPrompt < 0 {
		reqPrompt = 0
	}
	snap := winner.snapshot
	// Occupancy-aware estimate (base + occupancy term). The occupancy term lives
	// here, in the SHADOW path only — ttftMsFromSnapshot (the live cost / ceiling /
	// bestTTFT input) stays occupancy-free so raising alpha cannot tighten the
	// live 5s HARD_REJECT ceiling. See occupancyAwareTTFTMsFromSnapshot.
	estimate := occupancyAwareTTFTMsFromSnapshot(snap, reqPrompt)
	deadline := ttftDeadlineMsForPrompt(reqPrompt)
	occ := snapshotOccupancy(snap)

	eval := ttftShadowEval{
		Evaluated: true,
		Mode:      mode.String(),
		// Providers without BackendCapacity have no reliable TTFT estimate
		// (ttftMsFromSnapshot returns 0), so they never "would_shed" — matching
		// the live ceiling's behavior.
		WouldShed:  snap.hasBackendCapacity && estimate > deadline,
		EstimateMs: estimate,
		DeadlineMs: deadline,
		Occupancy:  occ,
	}
	// The spread signal only makes sense when the winner is itself herded: if we
	// already routed to an idle box (occ == 0) there was nothing better to spread
	// to. When herded, check whether an instantly-usable loaded-idle peer for the
	// same model was routable.
	if occ > 0 {
		eval.IdleAlternativeExists = r.loadedIdleAlternativeExistsLocked(model, pr, winner.provider)
	}
	return eval
}

// loadedIdleAlternativeExistsLocked reports whether some provider OTHER than the
// winner is a routable, model-resident, zero-occupancy candidate for model — an
// instantly-usable box the herded request could have been spread to. It applies
// the SAME gates the scheduler's selection loop does so it cannot report a peer
// the scheduler would have rejected (which would corrupt the Phase-0 spread
// metric): structural gates + owner/self-route filtering (snapshotProviderLockedEx),
// the vision-capability gate (providerServesVisionModelLocked, for media
// requests), and the capacity / token-budget / hardware-fit feasibility predicate
// (buildCandidateWithReason — the exact check the selection loop runs). Caller
// holds r.mu and no provider lock.
func (r *Registry) loadedIdleAlternativeExistsLocked(model string, pr *PendingRequest, winner *Provider) bool {
	winnerID := ""
	if winner != nil {
		winnerID = winner.ID
	}
	for _, p := range r.providers {
		if p == nil || p.ID == winnerID {
			continue
		}
		owned := providerOwnedBy(p, pr.OwnerAccountID)
		if pr.SelfRouteOnly && !owned {
			continue
		}
		relaxTrust := owned && (pr.SelfRouteOnly || pr.PreferOwner)
		snap, ok := r.snapshotProviderLockedEx(p, model, pr.Traits, relaxTrust, false)
		if !ok || !snap.modelLoaded {
			continue
		}
		// A spread target must be instantly usable — model resident AND
		// unoccupied. Filter occupied peers before the costlier gates below.
		if snapshotOccupancy(snap) != 0 {
			continue
		}
		// Vision gate: a media request must only count a vision-capable peer, or
		// the scheduler would have rejected it (visionRejections) and the spread
		// signal would be a false positive. snapshotProviderLockedEx released p.mu,
		// so re-take it for the p.Models read (mirrors the selection loop).
		if pr.RequiresVision {
			p.mu.Lock()
			servesVision := r.providerServesVisionModelLocked(p, model)
			p.mu.Unlock()
			if !servesVision {
				continue
			}
		}
		// Capacity / token-budget / hardware-fit feasibility — the same predicate
		// the selection loop applies via buildCandidateWithReason. Without it an
		// oversized-token or memory-starved peer would be counted as a valid idle
		// alternative the scheduler could never actually have selected.
		if _, _, admissible := r.buildCandidateWithReason(snap, pr); !admissible {
			continue
		}
		return true
	}
	return false
}
