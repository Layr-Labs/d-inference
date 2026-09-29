package promptwork

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Gate bounds optional HTTP-layer accounting before JSON serialization, with
// no waiter queue. The shared promptcontract client remains the sole tokenizer
// transport; its own worker/readiness limits apply inside this outer bound.
// At most 16 bodies of at most the client's 4MiB default enter concurrently.
type Gate struct{ slots chan struct{} }

func NewGate() *Gate { return &Gate{slots: make(chan struct{}, 16)} }
func (g *Gate) Acquire(ctx context.Context, bytes int) (func(), bool) {
	if g == nil || ctx.Err() != nil || bytes <= 0 || bytes > promptcontract.DefaultMaxRequestBytes {
		return nil, false
	}
	select {
	case g.slots <- struct{}{}:
		return func() { <-g.slots }, true
	default:
		return nil, false
	}
}

// PlanningContext spends the original request clock. Exempt requests retain
// only the sidecar timeout; an expired clock is never interpreted as exempt.
func PlanningContext(ctx context.Context, received time.Time, budget time.Duration) (context.Context, context.CancelFunc) {
	if budget > 0 && !received.IsZero() {
		return context.WithDeadline(ctx, received.Add(budget))
	}
	return context.WithCancel(ctx)
}

func Exact(plan promptcontract.Plan, artifact string) *protocol.PromptWork {
	if !plan.Participating {
		return nil
	}
	work := &protocol.PromptWork{Version: protocol.PromptWorkVersion, Source: protocol.PromptWorkExact,
		PromptTokens: int(plan.PromptTokenCount), UpperBoundTokens: int(plan.PromptTokenCount),
		PromptContractID: plan.PromptContractID, ModelArtifactHash: artifact}
	if !work.IsQualifiedFor(artifact, plan.PromptContractID) {
		return nil
	}
	return work
}

func Heuristic(tokens int) *protocol.PromptWork {
	if tokens <= 0 || tokens > protocol.MaxPromptWorkTokens {
		return nil
	}
	// Zero upper bound explicitly means unknown uncertainty, not zero work.
	return &protocol.PromptWork{Version: protocol.PromptWorkVersion,
		Source: protocol.PromptWorkHeuristic, PromptTokens: tokens}
}
