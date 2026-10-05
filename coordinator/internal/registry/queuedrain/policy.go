package queuedrain

import "github.com/eigeninference/d-inference/coordinator/internal/registry/memorypolicy"

// Work is a content-free request cohort and sizing quotation. Comparable is
// false for constrained ownership, provider pins, exclusions or cache plans.
type Work[T comparable] struct {
	Comparable              bool
	Vision                  bool
	Traits                  T
	PromptTokens, MaxTokens int
	MaxTTFTMs               float64
}

type Verdict struct {
	Candidates, CapacityRejections, TTFTRejections int
}

type dominanceKey[T comparable] struct {
	vision bool
	traits T
}

// Rejection is one immutable capacity/TTFT anchor owned by a drain pass.
type Rejection[T comparable] struct {
	key                     dominanceKey[T]
	promptTokens, maxTokens int
	maxTTFTMs               float64
	ttftRejections          int
}

func PureCapacityRejection(verdict Verdict) bool {
	return verdict.Candidates == 0 && (verdict.CapacityRejections > 0 || verdict.TTFTRejections > 0)
}

func requestSize[T comparable](work Work[T]) (prompt, maxTokens int) {
	prompt = max(0, work.PromptTokens)
	maxTokens = work.MaxTokens
	if maxTokens <= 0 {
		maxTokens = memorypolicy.DefaultRequestedMaxTokens
	}
	return prompt, maxTokens
}

func RejectionFor[T comparable](work Work[T], verdict Verdict) (Rejection[T], bool) {
	if !work.Comparable || !PureCapacityRejection(verdict) {
		return Rejection[T]{}, false
	}
	prompt, maxTokens := requestSize(work)
	return Rejection[T]{key: dominanceKey[T]{vision: work.Vision, traits: work.Traits},
		promptTokens: prompt, maxTokens: maxTokens, maxTTFTMs: work.MaxTTFTMs, ttftRejections: verdict.TTFTRejections}, true
}

func CeilingNoLooser(request, rejected float64) bool {
	return rejected <= 0 || (request > 0 && request <= rejected)
}

// Dominated preserves monotone capacity admission for the exact public cohort.
// A smaller request, different trait set or looser rejected TTFT ceiling scans.
func Dominated[T comparable](work Work[T], rejected []Rejection[T]) bool {
	if len(rejected) == 0 || !work.Comparable {
		return false
	}
	key := dominanceKey[T]{vision: work.Vision, traits: work.Traits}
	prompt, maxTokens := requestSize(work)
	for i := range rejected {
		record := &rejected[i]
		if record.key != key || prompt < record.promptTokens || maxTokens < record.maxTokens {
			continue
		}
		if record.ttftRejections > 0 && !CeilingNoLooser(work.MaxTTFTMs, record.maxTTFTMs) {
			continue
		}
		return true
	}
	return false
}
