// Package attempt coordinates request-scoped pre-content attempt operations.
package attempt

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type Outcome int

const (
	Committed Outcome = iota
	Accepted
	Retry
	FailFast
	ClientGone
	ResponseWritten
	Proceed
)

// Ingress arbitrates timer decisions against a provider frame whose ingress
// was published before classification. The provider remains the ingress owner.
type Ingress interface {
	Pending(*registry.PendingRequest) bool
}

type ProviderIngress struct{}

func (ProviderIngress) Pending(pr *registry.PendingRequest) bool {
	return pr.FirstContentIngressArrivedByDeadline()
}

type FirstWaitDependencies struct {
	Ingress     Ingress
	Commit      func(string)
	CommitReady func(protocol.InferenceErrorMessage) bool
	Failure     func(protocol.InferenceErrorMessage, bool)
	Refine      func(time.Duration)
	Speculate   func() Outcome
	Timeout     func() bool
	ClientGone  func()
}

type FirstWaitConfig struct {
	Pending       *registry.PendingRequest
	Timing        *registry.RequestTiming
	Deadline      time.Duration
	SpeculativeAt time.Duration
	HedgeAdvance  <-chan time.Time
}

type FirstWaitResult struct {
	Outcome          Outcome
	PreambleLiveness bool
}

// FirstWait owns the timer/ingress arbitration, not billing, settlement or
// provider transport. Those operations retain the request owner's authority.
type FirstWait struct {
	deps   FirstWaitDependencies
	config FirstWaitConfig
}

func NewFirstWait(deps FirstWaitDependencies, config FirstWaitConfig) *FirstWait {
	if deps.Ingress == nil {
		deps.Ingress = ProviderIngress{}
	}
	return &FirstWait{deps: deps, config: config}
}

func (w *FirstWait) Run(ctx context.Context, held *[]string) (result FirstWaitResult) {
	pr := w.config.Pending
	speculativeAt := w.config.SpeculativeAt
	clock := func() firstcontent.Clock {
		return firstcontent.NewClock(firstcontent.TimingReceivedAt(w.config.Timing), w.config.Deadline, speculativeAt).ForPending(pr)
	}
	deadlineWait := clock().Wait(w.config.Deadline)
	speculativeTimer := time.NewTimer(clock().SpeculativeWait())
	deadlineTimer := clock().Timer(deadlineWait)
	defer speculativeTimer.Stop()
	defer func() { deadlineTimer.Stop() }()
	hedgeAdvance := w.config.HedgeAdvance

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && firstcontent.HoldPreContentBoilerplate(pr, chunk, held) {
				clock().RearmExpired(&deadlineTimer)
				if clock().SpeculativeWait() <= 0 {
					speculativeTimer.Stop()
					deadlineTimer.Stop()
					result.Outcome = w.deps.Speculate()
					return result
				}
				continue
			}
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if ok {
				w.deps.Commit(chunk.Data)
			} else {
				select {
				case msg := <-pr.ErrorCh:
					w.deps.Failure(msg, true)
					result.Outcome = Retry
					return result
				default:
				}
			}
			result.Outcome = Committed
			return result

		case <-pr.AcceptedCh:
			// Acceptance is not content and cannot reset either timer.
			continue

		case msg := <-pr.ErrorCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if w.deps.CommitReady(msg) {
				result.Outcome = Committed
				return result
			}
			w.deps.Failure(msg, false)
			result.Outcome = Retry
			return result

		case at := <-hedgeAdvance:
			// One shot, strictly earlier, and never over a timer already fired.
			hedgeAdvance = nil
			receivedAt := firstcontent.TimingReceivedAt(w.config.Timing)
			if receivedAt.IsZero() || !at.Before(receivedAt.Add(speculativeAt)) {
				continue
			}
			if !speculativeTimer.Stop() {
				continue
			}
			speculativeAt = at.Sub(receivedAt)
			if speculativeAt < 0 {
				speculativeAt = 0
			}
			w.deps.Refine(speculativeAt)
			speculativeTimer.Reset(clock().SpeculativeWait())
			continue

		case <-speculativeTimer.C:
			if w.deps.Ingress.Pending(pr) {
				continue
			}
			deadlineTimer.Stop()
			result.Outcome = w.deps.Speculate()
			return result

		case <-deadlineTimer.C:
			speculativeTimer.Stop()
			if chunk, ok := firstcontent.DrainReadyFirstContent(pr, held); ok {
				w.deps.Commit(chunk.Data)
				result.Outcome = Committed
				return result
			}
			if w.deps.Ingress.Pending(pr) {
				continue
			}
			if len(*held) > 0 && clock().CanExtendPreamble() {
				result.PreambleLiveness = true
				result.Outcome = Accepted
				return result
			}
			if !w.deps.Timeout() {
				continue
			}
			result.Outcome = Retry
			return result

		case <-ctx.Done():
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			w.deps.ClientGone()
			result.Outcome = ClientGone
			return result
		}
	}
}
