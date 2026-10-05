package session

import (
	"context"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

type providerDrainBarrier struct {
	requestID  string
	generation uint64
}

// The socket reader is the sole producer. One worker and one coalesced latest
// barrier bound resources without dropping the final lifecycle barrier. Billing
// and reservation cleanup never block the reader's heartbeats or terminal ingress.
type DrainAcker struct {
	latest chan providerDrainBarrier
}

// Started reports whether this reader has begun drain coordination.
func (a *DrainAcker) Started() bool { return a.latest != nil }

func (a *DrainAcker,

) Offer(ctx context.Context, reg *registry.Registry, logger *slog.Logger, p *registry.Provider, terminalWork *CompletionBarrier,

	requestID string) bool {
	if a.latest == nil {
		a.latest = make(chan providerDrainBarrier, 1)
		saferun.Go(logger, "providerDrainAck", func() { a.run(ctx, reg, logger, p, terminalWork) })
	}
	generation := reg.CommitProviderDrain(p, requestID)
	if generation == 0 {
		return false
	}
	barrier := providerDrainBarrier{requestID: requestID, generation: generation}
	select {
	case a.latest <- barrier:
	default:
		// The reader owns submissions; the worker may already have taken the
		// previous value, so removing it must also remain non-blocking.
		select {
		case <-a.latest:
		default:
		}
		a.latest <- barrier
	}
	return true
}

func (a *DrainAcker,

) run(ctx context.Context, reg *registry.Registry, logger *slog.Logger, p *registry.Provider, terminalWork *CompletionBarrier,

) {
	var barrier providerDrainBarrier
nextBarrier:
	for {
		if barrier.generation == 0 {
			select {
			case barrier = <-a.latest:
			case <-ctx.Done():
				return
			}
		}
		pending, current := reg.ProviderDrainPending(p, barrier.generation)
		if !current {
			barrier = providerDrainBarrier{}
			continue
		}
		if pending != nil {
			select {
			case <-pending:
			case barrier = <-a.latest:
				continue
			case <-ctx.Done():
				return
			}
		}
		// Terminal ingress registers its billing work before removing pending
		// ownership. Snapshot AFTER reservation cleanup so a completion received
		// while draining cannot escape the final barrier's billing accounting.
		for {
			billing := terminalWork.Snapshot()
			if len(billing) == 0 {
				break
			}
			for _, done := range billing {
				select {
				case <-done:
				case barrier = <-a.latest:
					continue nextBarrier
				case <-ctx.Done():
					return
				}
			}
		}
		ackCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		if err := reg.WriteProviderDrainAck(ackCtx, p, barrier.requestID, barrier.generation); err != nil {
			logger.Warn("failed to send provider_drain acknowledgement", "provider_id", p.ID, "error", err)
		}
		cancel()
		barrier = providerDrainBarrier{}
	}
}
