package registry

import (
	"sort"
	"time"
)

// warm_pool_diagnostics.go answers the operator question that sits one layer
// BEYOND "is my machine routable": "my machine is routable, trusted and idle,
// the model is in my catalog — so why does the coordinator never send me a
// load_model for it?"
//
// Whether a cold (on-disk, not-loaded) provider is a warm-pool target is
// decided by warmPoolCandidateReasonLocked, which already classifies every
// refusal into a warmColdReason — including the two memory verdicts an operator
// most needs to see:
//
//	model_too_large    the model can never fit this box per the catalog's
//	                   authoritative min_ram_gb (or the size_gb heuristic)
//	no_free_for_load   the box's OWN reported free_for_load_gb says it cannot
//	                   fit the weights right now
//
// Those reasons are computed every control tick and then discarded. They reach
// a log line only when coldIneligible > 0 AND the model happens to be a
// dedicated model, and they reach no API at all. So the aggregate
// `cold_providers` count on /v1/models/capacity lumps "idle and warmable"
// together with "will never fit", and an operator whose box is permanently
// excluded by a catalog requirement sees a machine that reports itself online,
// trusted, routable and cold — indistinguishable from one that is simply
// waiting its turn.
//
// This file does NOT re-implement the gate. WarmPoolEligibility delegates to
// warmPoolCandidateReasonLocked, the same function the planner calls to build
// its action list, and maps the reason onto a stable wire string. A diagnostic
// and a warming decision cannot disagree because they are the same code.

// WarmPoolBlocker is a closed, operator-facing reason a provider is not a
// warm-pool (load_model) target for one model. Values are stable wire strings
// consumed by the console UI and `darkbloom status`, so renaming one is a
// breaking change.
type WarmPoolBlocker string

const (
	// WarmPoolBlockerNone means the provider IS an eligible warm target.
	WarmPoolBlockerNone WarmPoolBlocker = ""

	// Already warm — not a blocker, reported so a client can tell "already
	// loaded" apart from "eligible to load".
	WarmPoolBlockerAlreadyWarm WarmPoolBlocker = "already_warm"

	// Liveness / trust / privacy.
	WarmPoolBlockerOfflineUntrustedPrivate WarmPoolBlocker = "offline_untrusted_private"
	WarmPoolBlockerTrustOrRuntime          WarmPoolBlocker = "trust_or_runtime"
	WarmPoolBlockerStaleChallenge          WarmPoolBlocker = "stale_challenge"

	// Transient machine state.
	WarmPoolBlockerPendingLoadOrCooldown WarmPoolBlocker = "pending_load_or_cooldown"
	WarmPoolBlockerNotIdle               WarmPoolBlocker = "not_idle"
	WarmPoolBlockerThermalCritical       WarmPoolBlocker = "thermal_critical"

	// Catalog / routing policy.
	WarmPoolBlockerNotServingCatalog WarmPoolBlocker = "not_serving_catalog"
	WarmPoolBlockerDedicatedExcluded WarmPoolBlocker = "dedicated_excluded"

	// Memory. The two verdicts this whole file exists to surface.
	WarmPoolBlockerModelTooLarge  WarmPoolBlocker = "model_too_large"
	WarmPoolBlockerNoFreeForLoad  WarmPoolBlocker = "no_free_for_load"
	WarmPoolBlockerModelNotOnDisk WarmPoolBlocker = "model_not_on_disk"
)

// warmPoolBlockerFor maps the internal reason label onto the exported wire
// string. Kept as an explicit table rather than a cast so that renaming an
// internal label cannot silently change the public contract.
func warmPoolBlockerFor(reason warmColdReason) WarmPoolBlocker {
	switch reason {
	case warmColdEligible:
		return WarmPoolBlockerNone
	case warmColdOfflineUntrust:
		return WarmPoolBlockerOfflineUntrustedPrivate
	case warmColdPendingLoad:
		return WarmPoolBlockerPendingLoadOrCooldown
	case warmColdNotIdle:
		return WarmPoolBlockerNotIdle
	case warmColdThermal:
		return WarmPoolBlockerThermalCritical
	case warmColdTrust:
		return WarmPoolBlockerTrustOrRuntime
	case warmColdStaleChallenge:
		return WarmPoolBlockerStaleChallenge
	case warmColdNotServing:
		return WarmPoolBlockerNotServingCatalog
	case warmColdDedicated:
		return WarmPoolBlockerDedicatedExcluded
	case warmColdTooLarge:
		return WarmPoolBlockerModelTooLarge
	case warmColdNoFreeForLoad:
		return WarmPoolBlockerNoFreeForLoad
	default:
		// A new internal reason with no mapping must not silently read as
		// eligible. Surface the raw label; the closed-set test below fails so
		// this is caught in CI rather than in production.
		return WarmPoolBlocker(reason)
	}
}

// Description is a one-line, content-free explanation with the remediation an
// operator can act on. Never embeds request data — only fixed text.
func (b WarmPoolBlocker) Description() string {
	switch b {
	case WarmPoolBlockerNone:
		return "the machine is an eligible warm-pool target for this model"
	case WarmPoolBlockerAlreadyWarm:
		return "the model is already loaded on this machine"
	case WarmPoolBlockerOfflineUntrustedPrivate:
		return "the machine is offline, untrusted, or in private-only mode"
	case WarmPoolBlockerTrustOrRuntime:
		return "the machine's trust level or runtime verification is below what public routing requires"
	case WarmPoolBlockerStaleChallenge:
		return "the machine's last passing attestation challenge is older than the freshness window"
	case WarmPoolBlockerPendingLoadOrCooldown:
		return "a load is already in flight, or a recent load failure put this machine and model on a short cooldown"
	case WarmPoolBlockerNotIdle:
		return "the machine is serving requests; the coordinator only pre-loads onto a fully idle machine"
	case WarmPoolBlockerThermalCritical:
		return "the machine reported a critical thermal state"
	case WarmPoolBlockerNotServingCatalog:
		return "the machine does not advertise this model, or the model is not in the coordinator's catalog"
	case WarmPoolBlockerDedicatedExcluded:
		return "this model only pre-loads onto machines dedicated to it; this machine also serves other model families"
	case WarmPoolBlockerModelTooLarge:
		return "this model's published memory requirement exceeds this machine's total memory, so it can never be pre-loaded here"
	case WarmPoolBlockerNoFreeForLoad:
		return "the machine's own last heartbeat reported less loadable memory than this model's weights need"
	case WarmPoolBlockerModelNotOnDisk:
		return "the weights are not present on this machine; the coordinator only pre-loads a model the machine already advertises"
	default:
		return string(b)
	}
}

// Permanent reports whether the blocker is a standing property of this machine
// and model rather than a transient one. Only the static hardware-fit verdict
// qualifies: it is derived from the catalog's published requirement against
// total installed memory, so it cannot clear without changing the hardware or
// the catalog entry. Everything else — including no_free_for_load, which is a
// live measurement — can clear on the next heartbeat.
//
// This distinction is the point of the whole surface: it separates "wait" from
// "this will never happen on this box".
func (b WarmPoolBlocker) Permanent() bool {
	return b == WarmPoolBlockerModelTooLarge
}

// ModelWarmPoolEligibility is the warm-pool verdict for one model on one
// machine.
type ModelWarmPoolEligibility struct {
	ID string `json:"id"`
	// Warm reports whether the model is currently loaded here (slot state
	// "running" or "idle").
	Warm bool `json:"warm"`
	// Eligible reports whether the coordinator would consider this machine as
	// a load_model target for this model right now. False when Warm is true —
	// an already-loaded model is not a warming candidate.
	Eligible bool `json:"eligible"`
	// Blocker is the reason Eligible is false, empty when eligible. Only the
	// FIRST failing gate is reported, matching the order the planner evaluates
	// them: clearing it may reveal another.
	Blocker WarmPoolBlocker `json:"blocker,omitempty"`
	// BlockerDescription is the operator-facing text for Blocker, so a client
	// does not have to carry its own copy of the mapping.
	BlockerDescription string `json:"blocker_description,omitempty"`
	// Permanent is true when Blocker cannot clear without a hardware or catalog
	// change. A permanent blocker means this machine will never be pre-loaded
	// with this model, however long it waits.
	Permanent bool `json:"permanent,omitempty"`
	// RequiredMemoryGB is the catalog's published requirement for this model:
	// min_ram_gb when set, else the size_gb heuristic's effective threshold.
	// Zero when the catalog publishes neither (the fit gate is then disabled
	// and fails open). Present regardless of verdict so an operator can see how
	// much headroom they are short of, or how much margin they have.
	RequiredMemoryGB float64 `json:"required_memory_gb,omitempty"`
	// WeightsGB is the catalog's on-disk weight size for the model, the figure
	// compared against the machine's reported free_for_load_gb. Zero when
	// unpublished.
	WeightsGB float64 `json:"weights_gb,omitempty"`
}

// ProviderWarmPoolEligibility is the coordinator's answer to "would you
// pre-load a model onto this machine, and if not, why not".
//
// Deliberately per-model: the same machine can be permanently too small for one
// build, transiently busy for a second, and an eligible target for a third. A
// single machine-level verdict would collapse exactly the distinction an
// operator needs.
type ProviderWarmPoolEligibility struct {
	// TotalMemoryGB is the memory basis the static fit gate used — the
	// machine's reported backend total when available, else the registered
	// hardware figure. Reported because the two can differ and the gate prefers
	// the former.
	TotalMemoryGB float64 `json:"total_memory_gb,omitempty"`
	// FreeForLoadGB is the machine's own last-reported maximum loadable model
	// weight, the input to the no_free_for_load verdict. Nil when the machine's
	// version does not report it, in which case that gate is skipped entirely
	// and only the static fit gate applies.
	FreeForLoadGB *float64 `json:"free_for_load_gb,omitempty"`
	// Models carries one row per model the machine advertises, sorted by id.
	Models []ModelWarmPoolEligibility `json:"models,omitempty"`
	// EligibleModels / WarmModels / PermanentlyBlockedModels are counts over
	// Models, so a client can render a summary without walking the rows.
	EligibleModels           int `json:"eligible_models"`
	WarmModels               int `json:"warm_models"`
	PermanentlyBlockedModels int `json:"permanently_blocked_models"`
	// ChallengeMaxAgeSeconds is the freshness window behind
	// stale_challenge, so a client can render "N of M minutes".
	ChallengeMaxAgeSeconds int `json:"challenge_max_age_seconds"`
}

// WarmPoolEligibility returns the warm-pool verdict for one live provider, or
// nil when the id is not connected. Safe to call from HTTP handlers; takes r.mu
// and p.mu internally. Read-only: it runs no planning pass and issues no
// load_model.
func (r *Registry) WarmPoolEligibility(providerID string, now time.Time) *ProviderWarmPoolEligibility {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.providers[providerID]
	if !ok {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return r.warmPoolEligibilityLocked(p, now)
}

// warmPoolEligibilityLocked builds the verdict. Caller holds r.mu and p.mu.
func (r *Registry) warmPoolEligibilityLocked(p *Provider, now time.Time) *ProviderWarmPoolEligibility {
	out := &ProviderWarmPoolEligibility{
		ChallengeMaxAgeSeconds: int(challengeFreshnessMaxAge.Seconds()),
	}

	// Same memory basis the candidate gate uses: prefer the machine's own
	// reported backend total over the registered hardware figure.
	out.TotalMemoryGB = float64(p.Hardware.MemoryGB)
	if p.BackendCapacity != nil {
		if p.BackendCapacity.TotalMemoryGB > 0 {
			out.TotalMemoryGB = p.BackendCapacity.TotalMemoryGB
		}
		if free := p.BackendCapacity.FreeForLoadGB; free != nil {
			v := *free
			out.FreeForLoadGB = &v
		}
	}

	seen := make(map[string]struct{}, len(p.Models))
	out.Models = make([]ModelWarmPoolEligibility, 0, len(p.Models))
	for _, m := range p.Models {
		if m.ID == "" {
			continue
		}
		if _, dup := seen[m.ID]; dup {
			continue
		}
		seen[m.ID] = struct{}{}

		row := ModelWarmPoolEligibility{
			ID:               m.ID,
			RequiredMemoryGB: r.requiredMemoryGBLocked(m.ID),
			WeightsGB:        r.catalogSizeGBLocked(m.ID),
		}

		// An already-warm machine is not a warming candidate, and
		// warmPoolCandidateReasonLocked is only meaningful for cold ones — the
		// controller checks warmth first and never calls it on a warm provider.
		// Mirror that order here.
		if r.providerHasWarmModelLocked(p, m.ID, now) {
			row.Warm = true
			row.Blocker = WarmPoolBlockerAlreadyWarm
			row.BlockerDescription = WarmPoolBlockerAlreadyWarm.Description()
			out.WarmModels++
			out.Models = append(out.Models, row)
			continue
		}

		// Delegate to the SAME predicate the planner uses. Not a second
		// implementation.
		_, reason := r.warmPoolCandidateReasonLocked(p, m.ID, now)
		row.Blocker = warmPoolBlockerFor(reason)
		row.Eligible = row.Blocker == WarmPoolBlockerNone
		if !row.Eligible {
			row.BlockerDescription = row.Blocker.Description()
			row.Permanent = row.Blocker.Permanent()
			if row.Permanent {
				out.PermanentlyBlockedModels++
			}
		} else {
			out.EligibleModels++
		}
		out.Models = append(out.Models, row)
	}
	sort.Slice(out.Models, func(i, j int) bool { return out.Models[i].ID < out.Models[j].ID })
	return out
}

// requiredMemoryGBLocked reports the total-memory threshold modelFitsHardware
// applies for this model, in GB: the catalog's authoritative min_ram_gb when
// published, else the weight-size heuristic's effective threshold, else 0 when
// the catalog publishes neither and the gate is disabled. Mirrors
// modelFitsHardware's precedence exactly so the number an operator reads is the
// number the gate compared against. Caller holds r.mu.
func (r *Registry) requiredMemoryGBLocked(model string) float64 {
	if minRAM := r.catalogMinRAMGbLocked(model); minRAM > 0 {
		return float64(minRAM)
	}
	if size := r.catalogSizeGBLocked(model); size > 0 {
		return size * modelMemoryHeadroomFactor
	}
	return 0
}
