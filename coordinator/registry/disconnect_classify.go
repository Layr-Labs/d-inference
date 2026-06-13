package registry

// Disconnect classification. A jetsam OOM kills the provider with an uncatchable
// SIGKILL, so its only trace is the WebSocket abruptly dying ("read_error"),
// bucketed identically to a graceful close. We can't prove an OOM, but the last
// heartbeat carries memory pressure and we know the in-flight count: an abrupt
// drop under high pressure with active inference is very likely a jetsam kill.

// DisconnectReason is the classified cause of a provider socket drop.
type DisconnectReason string

const (
	DisconnectReasonNormal       DisconnectReason = "disconnect"    // graceful/unattributed
	DisconnectReasonOOMSuspected DisconnectReason = "oom_suspected" // abrupt drop under memory pressure
)

// Precision-tuned: ≥0.90 pressure is on the edge regardless of load; active
// inference lowers the bar to 0.80 (decode is the allocation that tips it over).
const (
	oomPressureHard         = 0.90
	oomPressureWithInFlight = 0.80
)

// ClassifyDisconnectReason: does an abrupt disconnect look like an OOM, from the
// last-known memory pressure + in-flight count? `abrupt` false = graceful close.
func ClassifyDisconnectReason(abrupt bool, memoryPressure float64, inFlight int) DisconnectReason {
	if !abrupt {
		return DisconnectReasonNormal
	}
	if memoryPressure >= oomPressureHard {
		return DisconnectReasonOOMSuspected
	}
	if inFlight > 0 && memoryPressure >= oomPressureWithInFlight {
		return DisconnectReasonOOMSuspected
	}
	return DisconnectReasonNormal
}

// DisconnectDiagnostics returns the signals used to classify a disconnect, read
// atomically under the provider lock.
func (p *Provider) DisconnectDiagnostics() (memoryPressure float64, inFlight int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.SystemMetrics.MemoryPressure, len(p.pendingReqs)
}
