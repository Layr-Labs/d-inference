package attempt

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type SingleWaitDependencies struct {
	Commit      func(string)
	CommitReady func(protocol.InferenceErrorMessage) bool
	Failure     func(protocol.InferenceErrorMessage, bool)
	Timeout     func() bool
	ClientGone  func()
}

// SingleWait continues the primary's original clock when no backup was sent.
// It does not own settlement, cancellation or the surviving attempt's identity.
type SingleWait struct {
	deps    SingleWaitDependencies
	pending *registry.PendingRequest
	clock   firstcontent.Clock
	wait    time.Duration
}

func NewSingleWait(deps SingleWaitDependencies, pending *registry.PendingRequest, clock firstcontent.Clock, wait time.Duration) *SingleWait {
	return &SingleWait{deps: deps, pending: pending, clock: clock, wait: wait}
}

func (w *SingleWait) Run(ctx context.Context, held *[]string) FirstWaitResult {
	pr := w.pending
	timer := w.clock.Timer(w.clock.Wait(w.wait))
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && firstcontent.HoldPreContentBoilerplate(pr, chunk, held) {
				continue
			}
			timer.Stop()
			if ok {
				w.deps.Commit(chunk.Data)
			} else {
				select {
				case msg := <-pr.ErrorCh:
					w.deps.Failure(msg, false)
					return FirstWaitResult{Outcome: Retry}
				default:
				}
			}
			return FirstWaitResult{Outcome: Committed}
		case <-pr.AcceptedCh:
			continue
		case msg := <-pr.ErrorCh:
			timer.Stop()
			if w.deps.CommitReady(msg) {
				return FirstWaitResult{Outcome: Committed}
			}
			w.deps.Failure(msg, true)
			return FirstWaitResult{Outcome: Retry}
		case <-timer.C:
			if chunk, ok := firstcontent.DrainReadyFirstContent(pr, held); ok {
				w.deps.Commit(chunk.Data)
				return FirstWaitResult{Outcome: Committed}
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(*held) > 0 && w.clock.Wait(firstcontent.PreambleContentTimeout) > 0 {
				return FirstWaitResult{Outcome: Accepted, PreambleLiveness: true}
			}
			if !w.deps.Timeout() {
				continue
			}
			return FirstWaitResult{Outcome: Retry}
		case <-ctx.Done():
			timer.Stop()
			w.deps.ClientGone()
			return FirstWaitResult{Outcome: ClientGone}
		}
	}
}
