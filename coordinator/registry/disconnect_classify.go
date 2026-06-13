package registry

// Disconnect classification. A macOS jetsam OOM kills the provider with an
// uncatchable SIGKILL, so the process flushes no crash report — the ONLY trace
// the coordinator sees is the WebSocket abruptly dying (a "read_error"). Today
// every such death is bucketed identically to a graceful close, so the ~7,880
// read-error disconnects/48h hide an unknown number of OOM kills.
//
// We can't prove an OOM from the coordinator, but the last heartbeat (≤ a few
// seconds old) carries the provider's memory pressure, and we know whether
// requests were in flight. A box that drops the socket while reporting high
// memory pressure with active inference is, with high probability, a jetsam
// kill. Classifying these turns invisible OOMs into an attributable signal.

// DisconnectReason is the classified cause of a provider socket drop.
type DisconnectReason string

const (
	// DisconnectReasonNormal is a graceful/unattributed disconnect.
	DisconnectReasonNormal DisconnectReason = "disconnect"
	// DisconnectReasonOOMSuspected is an abrupt drop whose last-known state
	// (high memory pressure, especially with in-flight requests) is consistent
	// with a jetsam OOM kill.
	DisconnectReasonOOMSuspected DisconnectReason = "oom_suspected"
)

// OOM-suspicion thresholds. Tuned to favor precision: a box at ≥0.90 pressure
// is on the edge regardless of load; active inference lowers the bar to 0.80
// because decode is the allocation that tips it over.
const (
	oomPressureHard         = 0.90
	oomPressureWithInFlight = 0.80
)

// ClassifyDisconnectReason decides whether an abrupt disconnect looks like an
// OOM, from the last-known memory pressure and in-flight request count. Pure
// and table-tested. `abrupt` is false for a graceful close (which is never an
// OOM).
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

// DisconnectDiagnostics returns the last-known signals used to classify a
// disconnect, read atomically under the provider lock. Safe to call from
// outside the registry package (e.g. the WS read loop on read error).
func (p *Provider) DisconnectDiagnostics() (memoryPressure float64, inFlight int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.SystemMetrics.MemoryPressure, len(p.pendingReqs)
}
