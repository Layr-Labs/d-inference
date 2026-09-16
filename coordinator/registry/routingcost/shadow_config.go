package routingcost

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
)

// Policy.ShadowDeadlineMs is the shadow gate's per-request upstream SLA in ms.
// Ordinary models use the configured ~10s base; exact per-model overrides use
// the same shared policy table as the live coordinator clock. This remains
// shadow only and does not change routing decisions.
func (policy *Policy[Connection]) ShadowDeadlineMs(model string, promptTokens int) float64 {
	defaultBase := time.Duration(policy.ttftDeadlineBaseMs * float64(time.Millisecond))
	deadline := modelpolicy.UpstreamFirstContentDeadline(model, promptTokens, defaultBase)
	return float64(deadline) / float64(time.Millisecond)
}

// Policy.SetTTFTAdmissionMode sets the Phase-0 admission mode. Must be called before
// serving starts.
func (policy *Policy[Connection]) SetTTFTAdmissionMode(mode TTFTAdmissionMode) {
	policy.ttftAdmissionMode = mode
}

// Policy.TTFTAdmissionModeValue returns the configured admission mode.
func (policy *Policy[Connection]) TTFTAdmissionModeValue() TTFTAdmissionMode {
	return policy.ttftAdmissionMode
}

// Policy.SetTTFTDeadlineBaseMs overrides the shadow-evaluation deadline base (ms).
// Values <= 0 are ignored (keep the verified ~10s default). Must be called
// before serving starts.
func (policy *Policy[Connection]) SetTTFTDeadlineBaseMs(ms float64) {
	if ms > 0 {
		policy.ttftDeadlineBaseMs = ms
	}
}

// Policy.TTFTDeadlineBaseMs returns the configured shadow-evaluation deadline base (ms).
func (policy *Policy[Connection]) TTFTDeadlineBaseMs() float64 {
	return policy.ttftDeadlineBaseMs
}

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

// DefaultTTFTDeadlineBaseMs is the verified standard OpenRouter SLA base.
// Standard-model cancels fit `10000 + 1ms·prompt_tokens` at a median ratio of
// 1.002 (telemetry-db findings §2). The live coordinator cutoff is selected
// separately with response headroom; exact-model policy can tighten either
// clock without conflating the two.
const DefaultTTFTDeadlineBaseMs = 10000.0
