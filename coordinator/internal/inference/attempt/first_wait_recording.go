package attempt

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/outcome"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// FirstWaitTerminal is the terminal decision made by the request owner after
// arbitration. A nil Build leaves accounting to an ongoing accepted wait.
type FirstWaitTerminal struct {
	Current outcome.Attempt
	Build   func(*registry.PendingRequest) *store.InferenceRouteOutcome
}

// RunRecorded keeps arbitration and its deferred terminal accounting together.
// Recovery may release the active binding, or speculation may replace/finalize
// it; the captured identity is therefore retained across the entire wait.
func (w *FirstWait) RunRecorded(ctx context.Context, held *[]string, captured outcome.Attempt, recorder *outcome.Recorder, model string, terminal func(FirstWaitResult) FirstWaitTerminal) (result FirstWaitResult) {
	defer func() {
		end := terminal(result)
		if end.Build != nil {
			end.Current.RecordAfterWait(captured, recorder, model, end.Build)
		}
	}()
	return w.Run(ctx, held)
}
