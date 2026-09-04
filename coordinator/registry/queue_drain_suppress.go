package registry

// Heartbeat-triggered queue-drain suppression.
//
// Every heartbeat from a provider re-runs the queue drain for the models it
// serves (Registry.Heartbeat), synchronously on that provider's WebSocket read
// loop. Fleet-wide that is ~260 passes/s, and under saturation each pass costs
// a full fleet scan (one ReserveProviderEx over every advertiser of the model)
// only to re-derive "no candidate". Heartbeats almost never free capacity
// themselves — completions, cancels, failed attempts (SetProviderIdle),
// challenge recoveries (RecordChallengeSuccess), disconnects, and load_model
// completions (DrainQueuedRequestsForModelWithReason) do, and those triggers
// are never suppressed. So a heartbeat skips a model whose last drain pass
// ended in a pure capacity/TTFT rejection less than heartbeatDrainSuppressWindow
// ago, and arms one trailing pass at the end of the window instead.

import (
	"sync"
	"time"
)

// heartbeatDrainSuppressWindow bounds how soon after a saturated drain pass a
// HEARTBEAT may trigger another pass for the same model. A suppressed
// heartbeat is not dropped: it arms ONE trailing pass at the end of the
// window, so capacity that only a heartbeat could have revealed (a
// budget-clamp release proof, a lower active-token report replacing the
// pessimistic pending ledger) is drained at most 20 ms late rather than
// waiting for the next un-suppressed trigger. Every other trigger drains at
// once. Deliberately a constant, not an env knob.
const heartbeatDrainSuppressWindow = 20 * time.Millisecond

// queueDrainSuppressor remembers, per model, when a drain pass last ended in a
// pure capacity/TTFT rejection without admitting anything. The zero value is
// ready to use; the maps are created on first mark.
type queueDrainSuppressor struct {
	mu        sync.Mutex
	saturated map[string]time.Time
	// trailing marks models for which a suppressed heartbeat has already
	// armed the end-of-window pass, so N suppressed heartbeats inside one
	// window cost exactly one trailing drain.
	trailing map[string]bool
	// now is a test-only clock seam so the window can be crossed without
	// sleeping. Production leaves it nil (time.Now).
	now func() time.Time
	// afterFunc is a test-only seam for scheduling the trailing pass; nil
	// means time.AfterFunc. Tests that do not exercise the trailing pass
	// install a no-op so its goroutine cannot race their fake clock.
	afterFunc func(time.Duration, func())
	// trailingDone, when set, is called after a trailing pass completes
	// (test synchronization; production leaves it nil).
	trailingDone func(model string)
}

func (s *queueDrainSuppressor) clock() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

// markSaturated records that a drain pass for model just ended saturated.
func (s *queueDrainSuppressor) markSaturated(model string) {
	now := s.clock()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.saturated == nil {
		s.saturated = make(map[string]time.Time)
	}
	s.saturated[model] = now
}

// clear forgets the saturation mark for model (a pass admitted a request).
func (s *queueDrainSuppressor) clear(model string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.saturated, model)
}

// suppressed reports whether model's last drain pass ended saturated less than
// heartbeatDrainSuppressWindow ago.
func (s *queueDrainSuppressor) suppressed(model string) bool {
	return s.suppressedAt(model, s.clock())
}

func (s *queueDrainSuppressor) suppressedAt(model string, now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	last, ok := s.saturated[model]
	return ok && now.Sub(last) < heartbeatDrainSuppressWindow
}

// unsuppressed returns the subset of models a heartbeat-triggered drain should
// still visit. It returns models itself when nothing is suppressed.
func (s *queueDrainSuppressor) unsuppressed(models []string) []string {
	now := s.clock()
	var kept []string
	for i, model := range models {
		if !s.suppressedAt(model, now) {
			if kept != nil {
				kept = append(kept, model)
			}
			continue
		}
		if kept == nil {
			kept = append(make([]string, 0, len(models)-1), models[:i]...)
		}
	}
	if kept == nil {
		return models
	}
	return kept
}

// drainQueuedRequestsForHeartbeat is the heartbeat-triggered drain: identical
// to drainQueuedRequestsForModelsWithReason(models, DrainTriggerHeartbeat)
// except that models whose queue was found saturated within
// heartbeatDrainSuppressWindow are skipped and given one trailing pass.
// Capacity-freeing triggers must keep calling the WithReason drain directly.
func (r *Registry) drainQueuedRequestsForHeartbeat(models []string) {
	if len(models) == 0 {
		return
	}
	kept := r.drainSuppress.unsuppressed(models)
	if len(kept) != len(models) {
		r.metricCount("queue.drain.suppressed", int64(len(models)-len(kept)), []string{"trigger:" + DrainTriggerHeartbeat})
		r.armTrailingDrains(models, kept)
	}
	r.drainQueuedRequestsForModelsWithReason(kept, DrainTriggerHeartbeat)
}

// armTrailingDrains schedules one end-of-window drain for every model the
// heartbeat was suppressed on (those in models but not in kept) that does not
// already have one armed. The trailing pass goes through the WithReason drain
// directly (never suppressed), stamped DrainTriggerHeartbeat because a
// heartbeat is what asked for it, and clears its own arm first so a heartbeat
// arriving after it runs can arm the next one.
func (r *Registry) armTrailingDrains(models, kept []string) {
	keptSet := make(map[string]struct{}, len(kept))
	for _, m := range kept {
		keptSet[m] = struct{}{}
	}
	s := &r.drainSuppress
	s.mu.Lock()
	if s.trailing == nil {
		s.trailing = make(map[string]bool)
	}
	var arm []string
	for _, m := range models {
		if _, ok := keptSet[m]; ok || s.trailing[m] {
			continue
		}
		s.trailing[m] = true
		arm = append(arm, m)
	}
	s.mu.Unlock()
	schedule := s.afterFunc
	if schedule == nil {
		schedule = func(d time.Duration, f func()) { time.AfterFunc(d, f) }
	}
	for _, model := range arm {
		model := model
		schedule(heartbeatDrainSuppressWindow, func() {
			s.mu.Lock()
			delete(s.trailing, model)
			s.mu.Unlock()
			r.drainQueuedRequestsForModelsWithReason([]string{model}, DrainTriggerHeartbeat)
			if s.trailingDone != nil {
				s.trailingDone(model)
			}
		})
	}
}
