package registry

// Per-model drain-pass coalescing.
//
// A drain pass (drainModelQueuePass) pops the model's queued requests and holds
// the ones it rejects or skips until it requeues them at the end. Passes for
// the same model were not otherwise serialized — heartbeats, SetProviderIdle,
// challenge recoveries, disconnects, and load completions each ran their own —
// so a trigger landing while a pass held waiters popped an empty queue and did
// nothing, while the running pass never re-examined what it held: a request it
// had already rejected, and every later request skipped on that verdict
// (queue_drain_dominance.go), was requeued against fleet state the trigger had
// since changed, and nothing rescanned them until the next trigger for the
// model — up to a heartbeat interval away — although capacity for them existed
// now. (The saturation mark is installed after the requeue, so a heartbeat
// that landed mid-pass was not suppressed and armed no trailing pass.)
//
// So one pass runs per model at a time. A trigger that finds a pass in flight
// records itself and returns; the pass, after requeueing, goes around once
// more with fresh fleet state and empty dominance records, attributed to the
// trigger that asked. Every trigger's work is therefore done by the pass that
// was running when it arrived, never later than one extra pass, and N triggers
// inside one pass cost one rerun.

import "sync"

// queueDrainCoalescer tracks, per model, whether a drain pass is in flight and
// which trigger arrived while it ran. The zero value is ready to use.
type queueDrainCoalescer struct {
	mu      sync.Mutex
	running map[string]bool
	// rerun holds the trigger reason of the latest drain that arrived while a
	// pass for the model was in flight.
	rerun map[string]string
}

// begin claims the drain pass for model. It returns false when a pass is
// already in flight; that pass reruns for reason once it has requeued.
func (c *queueDrainCoalescer) begin(model, reason string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.running[model] {
		if c.rerun == nil {
			c.rerun = make(map[string]string)
		}
		c.rerun[model] = reason
		return false
	}
	if c.running == nil {
		c.running = make(map[string]bool)
	}
	c.running[model] = true
	return true
}

// end is called by the claim holder after a completed pass. When a trigger
// arrived mid-pass it keeps the claim and returns that trigger's reason with
// true so the holder runs another pass; otherwise it releases the claim.
func (c *queueDrainCoalescer) end(model string) (reason string, again bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if reason, ok := c.rerun[model]; ok {
		delete(c.rerun, model)
		return reason, true
	}
	delete(c.running, model)
	return "", false
}

// abandon releases the claim for a pass that did not complete (a panic
// unwinding through the drain), dropping any rerun request with it, so the
// model is not pinned unroutable-from-queue by a claim nobody holds.
func (c *queueDrainCoalescer) abandon(model string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.running, model)
	delete(c.rerun, model)
}
