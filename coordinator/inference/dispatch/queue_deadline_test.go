package dispatch

import (
	"net/http"
	"testing"
)

// TestResolveDominantExhaustedStatus_QueueDeadline pins the classification at
// the unit level: the queue-wait synthetic 504 reclassifies to a 429 with
// reason queue_deadline; the dispatched-provider synthetic 504 keeps
// first_chunk_timeout; a sticky genuine provider fault is never overridden.
func TestResolveDominantExhaustedStatus_QueueDeadline(t *testing.T) {
	srv := newTestController(t)
	newState := func() *execution {
		return &execution{s: srv, model: "m", excludeProviders: map[string]struct{}{}}
	}

	d := newState()
	d.setLastError(errQueueDeadlineExpired, http.StatusGatewayTimeout)
	failure, sticky := d.terminalFailureForExhaustion()
	code, reason, reclassified, dominance := d.resolveDominantExhaustedStatus(failure, sticky)
	if code != http.StatusTooManyRequests || reason != RejectionReasonQueueDeadline || !reclassified || dominance != exhaustedUndecided {
		t.Fatalf("queue deadline = (%d, %q, %v, %d), want (429, queue_deadline, true, undecided)", code, reason, reclassified, dominance)
	}

	d = newState()
	d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
	failure, sticky = d.terminalFailureForExhaustion()
	code, reason, reclassified, _ = d.resolveDominantExhaustedStatus(failure, sticky)
	if code != http.StatusTooManyRequests || reason != "first_chunk_timeout" || !reclassified {
		t.Fatalf("dispatched timeout = (%d, %q, %v), want (429, first_chunk_timeout, true)", code, reason, reclassified)
	}

	// A sticky genuine fault from an earlier attempt outranks the queue's
	// terminal: its own text, its own status.
	d = newState()
	fault := dispatchTerminalFailure{errText: "boom", statusCode: http.StatusBadGateway}
	d.genuineFault = &fault
	d.setLastError(errQueueDeadlineExpired, http.StatusGatewayTimeout)
	failure, sticky = d.terminalFailureForExhaustion()
	code, reason, reclassified, dominance = d.resolveDominantExhaustedStatus(failure, sticky)
	if !sticky || code != http.StatusBadGateway || reason != "dispatch_exhausted" || reclassified || dominance != exhaustedGenuineFault {
		t.Fatalf("sticky fault = (%d, %q, %v, %d), want (502, dispatch_exhausted, false, genuine fault)", code, reason, reclassified, dominance)
	}
}
