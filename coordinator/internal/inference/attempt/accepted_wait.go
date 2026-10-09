package attempt

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type AcceptedWaitDependencies struct {
	Ingress     Ingress
	Commit      func(string)
	CommitReady func(protocol.InferenceErrorMessage) bool
	Failure     func(protocol.InferenceErrorMessage)
	Timeout     func(time.Duration) bool
	ClientGone  func()
}

type AcceptedWaitConfig struct {
	Pending          *registry.PendingRequest
	Clock            firstcontent.Clock
	Deadline         time.Duration
	PreambleLiveness bool
}

type AcceptedWait struct {
	deps   AcceptedWaitDependencies
	config AcceptedWaitConfig
}

func NewAcceptedWait(deps AcceptedWaitDependencies, config AcceptedWaitConfig) *AcceptedWait {
	if deps.Ingress == nil {
		deps.Ingress = ProviderIngress{}
	}
	return &AcceptedWait{deps: deps, config: config}
}

func (w *AcceptedWait) Run(ctx context.Context, held *[]string) Outcome {
	pr := w.config.Pending
	clock := w.config.Clock.ForPending(pr)
	budget := w.config.Deadline
	if w.config.PreambleLiveness {
		budget = firstcontent.PreambleContentTimeout
	}
	if remaining, ok := clock.Remaining(); ok && remaining < budget {
		budget = remaining
	}
	timer := clock.Timer(budget)
	defer func() { timer.Stop() }()
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && firstcontent.HoldPreContentBoilerplate(pr, chunk, held) {
				clock.RearmExpired(&timer)
				continue
			}
			timer.Stop()
			if ok {
				w.deps.Commit(chunk.Data)
			} else {
				// Preserve the original terminal-before-close arbitration window.
				select {
				case msg := <-pr.ErrorCh:
					w.deps.Failure(msg)
					return Retry
				case <-time.After(50 * time.Millisecond):
				}
			}
			return Committed
		case msg := <-pr.ErrorCh:
			timer.Stop()
			if w.deps.CommitReady(msg) {
				return Committed
			}
			w.deps.Failure(msg)
			return Retry
		case <-timer.C:
			if chunk, ok := firstcontent.DrainReadyFirstContent(pr, held); ok {
				w.deps.Commit(chunk.Data)
				return Committed
			}
			if w.deps.Ingress.Pending(pr) {
				continue
			}
			if !w.deps.Timeout(budget) {
				continue
			}
			return Retry
		case <-ctx.Done():
			w.deps.ClientGone()
			return ClientGone
		}
	}
}
