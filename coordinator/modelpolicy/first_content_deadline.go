package modelpolicy

import (
	"strconv"
	"strings"
	"sync"
	"time"
)

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

var (
	basesMu sync.RWMutex
	// exactBases keeps every per-model upstream/live pair in one exact-match
	// table. It defaults to the built-in policy
	// (defaultExactFirstContentDeadlineBases) and may be REPLACED once at
	// startup via SetFirstContentBasesFromEnv
	// (EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES) — the operator escape hatch
	// the 2026-09-01 incident lacked: the hardcoded Qwen3-VL 5s/4s pair can
	// only TIGHTEN the global base, so when vision success p90 sat at 3.4s
	// (right at the 4s line, ~47% of vision traffic killed) nothing short of
	// a rebuild could loosen it.
	exactBases = defaultExactFirstContentDeadlineBases()
)

// defaultExactFirstContentDeadlineBases is the built-in exact-model policy.
// Add future model-specific policies here so shadow evaluation and live
// dispatch cannot select different model sets.
func defaultExactFirstContentDeadlineBases() map[string]firstContentDeadlineBases {
	return map[string]firstContentDeadlineBases{
		Qwen3VL30BA3BInstructModelID: {
			upstream:    Qwen3VL30BA3BInstructUpstreamFirstContentBase,
			coordinator: Qwen3VL30BA3BInstructCoordinatorFirstContentBase,
		},
	}
}

func exactFirstContentDeadlineBases(model string) (firstContentDeadlineBases, bool) {
	basesMu.RLock()
	bases, ok := exactBases[model]
	basesMu.RUnlock()
	return bases, ok
}

// SetFirstContentBasesFromEnv parses an override of the form
// "<model>=<upstream_ms>,..." (e.g. "qwen3-vl-30b-a3b-instruct=8000") and
// REPLACES the exact-model table when at least one valid pair is present.
// Each valid pair replaces that model's upstream base; the coordinator base
// keeps the standard response margin (upstream − FirstContentResponseHeadroom).
// A value of 0 or "off" REMOVES the exact entry so the model falls back to the
// global base. Invalid pairs (malformed, non-numeric, or an upstream base not
// strictly above the headroom) are skipped; a blank string is a no-op. The
// exact-model policy remains a tightening ceiling relative to the global base
// (UpstreamFirstContentDeadline/CoordinatorFirstContentDeadline), so an
// override above the global base is inert rather than loosening it. Returns
// the number of pairs replaced and removed. Called once at startup from
// main.go, mirroring api.SetPromptContextCalibrationFromEnv.
func SetFirstContentBasesFromEnv(raw string) (replaced, removed int) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, 0
	}
	next := defaultExactFirstContentDeadlineBases()
	for _, pair := range strings.Split(raw, ",") {
		kv := strings.SplitN(strings.TrimSpace(pair), "=", 2)
		if len(kv) != 2 {
			continue
		}
		model := strings.TrimSpace(kv[0])
		value := strings.TrimSpace(kv[1])
		if model == "" {
			continue
		}
		if strings.EqualFold(value, "off") || value == "0" {
			if _, ok := next[model]; ok {
				delete(next, model)
				removed++
			}
			continue
		}
		ms, err := strconv.Atoi(value)
		if err != nil || ms <= 0 {
			continue
		}
		upstream := time.Duration(ms) * time.Millisecond
		if upstream <= FirstContentResponseHeadroom {
			// The coordinator base (upstream − headroom) must stay positive.
			continue
		}
		next[model] = firstContentDeadlineBases{
			upstream:    upstream,
			coordinator: upstream - FirstContentResponseHeadroom,
		}
		replaced++
	}
	if replaced == 0 && removed == 0 {
		return 0, 0
	}
	basesMu.Lock()
	exactBases = next
	basesMu.Unlock()
	return replaced, removed
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
