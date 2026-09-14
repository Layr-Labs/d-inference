package dispatchplan

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// ProbeShape is the coordinator-side request shape a probe describes.
// PromptTokens is the coordinator's raw estimate; the wire message carries it
// bucketed (rounded UP to protocol.CapacityProbePromptBucketTokens) so a
// probed-but-never-chosen provider learns shape, not content.
type ProbeShape struct {
	Model             string
	PromptTokens      int
	MaxOutputTokens   int
	RequiresVision    bool
	VisionImageCount  int
	DeadlineRemaining time.Duration
}

// QuoteOutcome is one probe's settled result, delivered on the channel
// ProbePlanCandidates returns. Exactly one of the three states holds:
// Quote != nil (the provider answered — affirmative or negative, per
// Quote.AdmissibleNow), Timeout (silent through the window), or SendFailed
// (writer queue full, write error, or the provider disconnected). By the time
// an outcome is readable the plan has ALREADY been updated (ConfirmEntry /
// DemoteEntry) — the channel is informational, for hedge timing and telemetry,
// never a step the dispatch loop must apply itself.
type QuoteOutcome struct {
	ProviderID string
	Quote      *protocol.CapacityQuoteMessage
	Timeout    bool
	SendFailed bool
}

// Transport reads and writes the exact retained connection. Its callbacks
// never run under the plan or correlation mutex. Logger is read at each
// original logging/goroutine boundary to preserve the current binding.
type Transport[C comparable] struct {
	Ready  func(C) bool
	Write  func(C, context.Context, []byte) error
	Logger func() *slog.Logger
}
