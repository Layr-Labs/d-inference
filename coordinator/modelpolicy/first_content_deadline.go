package modelpolicy

import "time"

const (
	// Qwen3VL30BA3BInstructModelID is the concrete catalog identifier used by
	// the coordinator and providers for Qwen3-VL 30B A3B Instruct.
	Qwen3VL30BA3BInstructModelID = "qwen3-vl-30b-a3b-instruct"

	// StandardUpstreamFirstContentBase is the ordinary upstream first-content
	// SLA base. The request-specific deadline also adds 1ms per estimated prompt
	// token.
	StandardUpstreamFirstContentBase = 10 * time.Second

	// FirstContentResponseHeadroom is the response margin the coordinator keeps
	// inside the upstream SLA. It lets the coordinator return a retryable 429
	// before an upstream router closes a still-silent request.
	FirstContentResponseHeadroom = time.Second

	// Qwen3VL30BA3BInstructUpstreamFirstContentBase is the shorter upstream SLA
	// base for this exact concrete catalog build.
	Qwen3VL30BA3BInstructUpstreamFirstContentBase = 5 * time.Second

	// Qwen3VL30BA3BInstructCoordinatorFirstContentBase preserves the same 1s
	// response margin used by the ordinary production posture (10s upstream,
	// 9s coordinator) inside Qwen3-VL's 5s upstream SLA.
	Qwen3VL30BA3BInstructCoordinatorFirstContentBase = Qwen3VL30BA3BInstructUpstreamFirstContentBase - FirstContentResponseHeadroom
)

type firstContentDeadlineBases struct {
	upstream    time.Duration
	coordinator time.Duration
}

// exactFirstContentDeadlineBases keeps every per-model upstream/live pair in
// one exact-match table. Add future model-specific policies here so shadow
// evaluation and live dispatch cannot select different model sets.
func exactFirstContentDeadlineBases(model string) (firstContentDeadlineBases, bool) {
	switch model {
	case Qwen3VL30BA3BInstructModelID:
		return firstContentDeadlineBases{
			upstream:    Qwen3VL30BA3BInstructUpstreamFirstContentBase,
			coordinator: Qwen3VL30BA3BInstructCoordinatorFirstContentBase,
		}, true
	default:
		return firstContentDeadlineBases{}, false
	}
}

// UpstreamFirstContentDeadline returns the caller-facing first-content SLA for
// a concrete model. defaultBase is the ordinary-model base and remains
// operator-configurable. Exact-model policy is a tightening ceiling: a lower
// emergency global base still wins.
func UpstreamFirstContentDeadline(model string, estimatedPromptTokens int, defaultBase time.Duration) time.Duration {
	base := defaultBase
	if base <= 0 {
		base = StandardUpstreamFirstContentBase
	}
	if exact, ok := exactFirstContentDeadlineBases(model); ok && base > exact.upstream {
		base = exact.upstream
	}
	return addPromptTokenSlope(base, estimatedPromptTokens)
}

// CoordinatorFirstContentDeadline returns the live coordinator cutoff for a
// concrete model. defaultBase is the instance-owned ordinary-model cutoff
// (9s in production); the exact Qwen3-VL override keeps one second of response
// headroom inside its shorter upstream SLA. Exact-model policy never loosens a
// tighter emergency global base.
func CoordinatorFirstContentDeadline(model string, estimatedPromptTokens int, defaultBase time.Duration) time.Duration {
	base := defaultBase
	if base <= 0 {
		base = StandardUpstreamFirstContentBase - FirstContentResponseHeadroom
	}
	if exact, ok := exactFirstContentDeadlineBases(model); ok && base > exact.coordinator {
		base = exact.coordinator
	}
	return addPromptTokenSlope(base, estimatedPromptTokens)
}

func addPromptTokenSlope(base time.Duration, estimatedPromptTokens int) time.Duration {
	if estimatedPromptTokens < 0 {
		estimatedPromptTokens = 0
	}
	return base + time.Duration(estimatedPromptTokens)*time.Millisecond
}
