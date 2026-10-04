package registry

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Disconnect applies an optional eviction guard atomically with removal.
// expected is the exact session observed by the stale scan; nil is an ordinary
// unconditional disconnect. A negative timeout is a pointer-only guard for
// canonical duplicate eviction. Otherwise its identity and heartbeat are checked
// while r.mu and p.mu exclude replacement and heartbeat updates. The supplied
// cause is stamped on every flushed pending-request terminal.
func (l *ConnectionLifecycle) Disconnect(id string, expected *Provider, timeout time.Duration, cause protocol.CoordinatorInferenceErrorCause) bool {
	r := l.registry
	var disconnectedModels []string
	releasedModelLoad := false
	r.mu.Lock()
	cacheTracker := r.cacheRouting
	p, ok := r.providers[id]
	if ok {
		if expected != nil && p != expected {
			r.mu.Unlock()
			return false
		}
		p.mu.Lock()
		if expected != nil && timeout >= 0 && time.Since(p.LastHeartbeat) <= timeout {
			p.mu.Unlock()
			r.mu.Unlock()
			return false
		}
		// Losing the session cannot prove delivery, final residency or rollback.
		// Queue only; the controller persists outside registry/provider locks.
		p.autopilotState.Disconnect(p.ID, time.Now, r.queueAutopilotEvent)
		r.providerDirectory.deleteLocked(id)
		p.transport.Reset()
		p.warmWork.Reset()
		if p.warmLoads != nil {
			p.warmLoads.Reset()
		}
		p.drain.Disconnect()
		p.appAttestAuthorization = AppAttestServingAuthorization{}
		// Clear any pending model load entries for this provider.
		releasedModelLoad = r.pendingLoads.DropProvider(id) > 0
		p.detachModelIndexLocked(r)
		// FAULT STATE IS NOT CLEARED ON DISCONNECT. Every fault tracker
		// (node-health breaker, inference-error cooldowns, dispatch-load
		// cooldowns, health ejection, capacity trackers) lives on the STABLE
		// identity's gate when one is bound, so it must survive reconnect
		// churn - wiping it here was the zombie exploit. detachSessionGate
		// caches the identity (keyed by this session id) before the pending
		// flush below so the 502 "provider disconnected" faults - the dominant
		// reconnecting-zombie signal - still resolve to it even though the
		// provider is already gone from r.providers; only a provider that never
		// had a stable identity (sid == "": its gate WAS this session id, which
		// never recurs) has its session-keyed residue dropped for hygiene.
		r.detachSessionGate(p, stableProviderIdentityLocked(p))
		disconnectedModels = make([]string, 0, len(p.Models))
		for _, m := range p.Models {
			disconnectedModels = append(disconnectedModels, m.ID)
		}
		if p.Status != StatusUntrusted {
			r.onlineCount.Add(-1)
			for _, m := range p.Models {
				r.modelProviderDec(m.ID)
			}
		}
		p.mu.Unlock()
	}
	r.mu.Unlock()

	if releasedModelLoad {
		r.RequestWarmPoolTrigger()
	}
	if !ok {
		return false
	}
	// Removing the last capable provider can turn a queued constrained request
	// from temporarily capacity-blocked into permanently unservable. Re-run
	// the canonical drain after removal so those waiters receive the immediate
	// capability-unavailable result instead of sleeping until maxWait.
	r.drainQueuedRequestsForModelsWithReason(disconnectedModels, DrainTriggerDisconnect)
	// Cache holders and nonce-bound attempts are connection-scoped. Clear them
	// after releasing registry/provider locks.
	cacheTracker.disconnect(id, cacheHolderRemovalDisconnect)
	// Outstanding capacity-probe waiters bound to this connection can never be
	// answered now (the socket is gone) - resolve them as SendFailed so probe
	// collectors demote the entries immediately instead of burning the full
	// quote window. Like the cache-holder cleanup above, this runs after the
	// registry/provider locks are released (capacityquote.Tracker has its own leaf
	// mutex; see capacity_quotes.go).
	r.capacityQuotes.FailProvider(id)

	// Close all pending request channels so consumers get errors. Pending
	// requests created by tests may leave these channels nil, and consumer
	// goroutines may have already closed them on a successful/error path. Use
	// non-nil checks and recover so a single bad request cannot hang or panic
	// the disconnect cleanup.
	p.mu.Lock()
	pending := p.pendingReqs
	for reqID, pr := range pending {
		if pr == nil {
			continue
		}
		if pr.ErrorCh != nil {
			func() {
				defer func() { recover() }()
				pr.ErrorCh <- protocol.InferenceErrorMessage{
					Type:             protocol.TypeInferenceError,
					RequestID:        reqID,
					Error:            "provider disconnected",
					StatusCode:       502,
					ErrorReason:      disconnectFlushErrorReason(cause),
					CoordinatorCause: cause,
				}
			}()
			func() {
				defer func() { recover() }()
				close(pr.ErrorCh)
			}()
		}
		if pr.ChunkCh != nil {
			func() {
				defer func() { recover() }()
				close(pr.ChunkCh)
			}()
		}
		if pr.CompleteCh != nil {
			func() {
				defer func() { recover() }()
				close(pr.CompleteCh)
			}()
		}
	}
	p.pendingReqs = make(map[string]*PendingRequest)
	p.serviceRetirement.Reset()
	p.serviceRetirementProtocol = false
	if p.deadlinePosture != nil {
		p.deadlinePosture.Reset()
	}
	p.settleDrainPendingLocked()
	p.mu.Unlock()
	for _, pr := range pending {
		if pr != nil {
			r.MarkCacheAttemptTerminal(pr)
		}
	}

	// Tear down the socket. Deleting the map entry only makes the provider
	// unroutable; its read loop and challenge loop keep running on the open
	// socket and the coordinator keeps auto-ponging it, so the provider never
	// detects the drop and never reconnects - a "zombie" that's unroutable yet
	// still reports stale trust locally. CloseNow unblocks the read loop, which
	// unwinds the rest, and re-arms the provider's reconnect. CloseNow not Close:
	// Disconnect runs serially in the eviction loop and Close would block ~5s
	// waiting for a handshake the stale peer won't send. No-op if already closed;
	// outside r.mu so it can't stall the registry.
	p.closeWriterNow()

	// Final reputation persist: job successes are persisted on a 30 s throttle
	// (RecordJobSuccess), so flush whatever accumulated since the last window
	// before the row goes cold. Async, like every other persist.
	r.persistReputation(p)

	// Close this connection's session row (async; durable uptime history).
	// Covers both graceful disconnects and stale-sweep removal.
	if r.store != nil {
		saferun.Go(r.logger, "registry.closeSession", func() {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := r.store.CloseProviderSession(ctx, id, "disconnect", time.Now()); err != nil {
				r.logger.Warn("failed to close provider session", "provider_id", id, "error", err)
			}
		})
	}

	r.logger.Info("provider disconnected", "provider_id", id)
	return true
}
