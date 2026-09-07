package registry

import "regexp"

// Must match ProviderCore.KVPerformanceIdentity. The finite grammar bounds key
// cardinality per model; malformed nonempty values share one quarantine key.
// Empty is the historical native key and is never synthesized from bad input.
const maxExecutionIdentityBytes = 160
const invalidExecutionIdentity = "kvq-v1:invalid"

var executionIdentityPattern = regexp.MustCompile(`^kvq-v1:affine-v1-k(4|8)v(4|8)-g(32|64|128)-f32-h(0|32|64|128|256|512)-s1:prefill=(direct|opportunisticSDPA)$`)

func normalizeExecutionIdentity(identity string) string {
	if identity == "" {
		return ""
	}
	if len(identity) > maxExecutionIdentityBytes || !executionIdentityPattern.MatchString(identity) {
		return invalidExecutionIdentity
	}
	return identity
}

func optionalExecutionIdentity(identity []string) string {
	if len(identity) == 0 {
		return ""
	}
	return normalizeExecutionIdentity(identity[0])
}

// Struct keys cannot collide with model/chip names containing separators.
type modelExecutionKey struct {
	model     string
	execution string
}

// Loaded slot execution takes precedence, including native omission. A
// nonresident placeholder is not a statement that the next load uses native KV.
// The provider's model declaration protects unloaded-model bootstrap.
// Caller holds p.mu.
func providerExecutionIdentityLocked(p *Provider, model string) string {
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == model && slotStateModelLoaded(slot.State) {
				return normalizeExecutionIdentity(slot.ExecutionIdentity)
			}
		}
	}
	for _, declared := range p.Models {
		if declared.ID == model {
			return normalizeExecutionIdentity(declared.ExecutionIdentity)
		}
	}
	return ""
}

// ExecutionIdentityForModelLocked exposes the same actual/declaration resolution
// to observational API readers. Caller must hold p.Mu().
func (p *Provider) ExecutionIdentityForModelLocked(model string) string {
	return providerExecutionIdentityLocked(p, model)
}

// Quantized execution has no registration/static hardware measurement. Zero
// means uncalibrated, not zero throughput; ranking uses its arithmetic floor,
// and TTFT admission permits a first measurement under the real deadline.
func modelBootstrapTPSLocked(p *Provider, model string) (decode, prefill float64) {
	if providerExecutionIdentityLocked(p, model) != "" {
		return 0, 0
	}
	return resolvedDecodeTPS(p), resolvedPrefillTPS(p)
}

func applyExecutionPerformanceSnapshot(snap *routingSnapshot, p *Provider, model string) {
	snap.executionIdentity = providerExecutionIdentityLocked(p, model)
	if snap.executionIdentity != "" {
		snap.decodeTPS, snap.prefillTPS = 0, 0
	}
	if snap.executionIdentity == invalidExecutionIdentity || (snap.executionIdentity != "" && !slotStateModelLoaded(snap.slotState)) {
		snap.observedDecodeTPS, snap.observedPrefillTPS = 0, 0
	}
}

// A nonresident placeholder has no actual engine whose EWMAs can attest the
// declared next execution format. Preserve legacy native behavior.
func executionSlotRatesCompatible(identity string, state string) bool {
	return identity != invalidExecutionIdentity && (identity == "" || slotStateModelLoaded(state))
}

func executionPrefillUncalibrated(snap *routingSnapshot) bool {
	return snap.executionIdentity != "" && snap.observedPrefillTPS <= 0
}

// Fleet display counts a provider once. Once it declares quantized execution,
// only execution-compatible per-model rates can represent its throughput.
func providerRatedDecodeTPSLocked(p *Provider) float64 {
	quantized := false
	for _, model := range p.Models {
		quantized = quantized || providerExecutionIdentityLocked(p, model.ID) != ""
	}
	if !quantized {
		return resolvedDecodeTPS(p)
	}
	best := 0.0
	for _, model := range p.Models {
		decode, _ := resolvedModelTPSLocked(p, model.ID)
		best = max(best, decode)
	}
	return best
}
