package registry

import "testing"

func TestClassifyDisconnectReason(t *testing.T) {
	tests := []struct {
		name           string
		abrupt         bool
		memoryPressure float64
		inFlight       int
		want           DisconnectReason
	}{
		{"graceful close is never OOM even at high pressure", false, 0.99, 5, DisconnectReasonNormal},
		{"abrupt + very high pressure, no inflight -> OOM", true, 0.92, 0, DisconnectReasonOOMSuspected},
		{"abrupt + high pressure + inflight -> OOM", true, 0.85, 2, DisconnectReasonOOMSuspected},
		{"abrupt + high pressure but no inflight -> normal", true, 0.85, 0, DisconnectReasonNormal},
		{"abrupt + moderate pressure + inflight -> normal", true, 0.70, 3, DisconnectReasonNormal},
		{"abrupt + low pressure -> normal", true, 0.10, 0, DisconnectReasonNormal},
		{"exactly hard threshold -> OOM", true, oomPressureHard, 0, DisconnectReasonOOMSuspected},
		{"exactly inflight threshold with inflight -> OOM", true, oomPressureWithInFlight, 1, DisconnectReasonOOMSuspected},
		{"just below inflight threshold with inflight -> normal", true, oomPressureWithInFlight - 0.01, 1, DisconnectReasonNormal},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ClassifyDisconnectReason(tt.abrupt, tt.memoryPressure, tt.inFlight)
			if got != tt.want {
				t.Errorf("ClassifyDisconnectReason(%v, %.2f, %d) = %q, want %q",
					tt.abrupt, tt.memoryPressure, tt.inFlight, got, tt.want)
			}
		})
	}
}

// The accessor must read the last-known metrics + in-flight count atomically.
func TestProviderDisconnectDiagnostics(t *testing.T) {
	p := &Provider{
		pendingReqs: make(map[string]*PendingRequest),
	}
	p.SystemMetrics.MemoryPressure = 0.93
	p.pendingReqs["r1"] = &PendingRequest{RequestID: "r1"}
	p.pendingReqs["r2"] = &PendingRequest{RequestID: "r2"}

	mp, inFlight := p.DisconnectDiagnostics()
	if mp != 0.93 {
		t.Errorf("memoryPressure = %f, want 0.93", mp)
	}
	if inFlight != 2 {
		t.Errorf("inFlight = %d, want 2", inFlight)
	}
	if got := ClassifyDisconnectReason(true, mp, inFlight); got != DisconnectReasonOOMSuspected {
		t.Errorf("classify = %q, want oom_suspected", got)
	}
}
