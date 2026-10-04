package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestClassifyDisconnectReason(t *testing.T) {
	tests := []struct {
		name           string
		abrupt         bool
		memoryPressure float64
		inFlight       int
		want           production.DisconnectReason
	}{
		{"graceful close is never OOM even at high pressure", false, 0.99, 5, production.DisconnectReasonNormal},
		{"abrupt + very high pressure, no inflight -> OOM", true, 0.92, 0, production.DisconnectReasonOOMSuspected},
		{"abrupt + high pressure + inflight -> OOM", true, 0.85, 2, production.DisconnectReasonOOMSuspected},
		{"abrupt + high pressure but no inflight -> normal", true, 0.85, 0, production.DisconnectReasonNormal},
		{"abrupt + moderate pressure + inflight -> normal", true, 0.70, 3, production.DisconnectReasonNormal},
		{"abrupt + low pressure -> normal", true, 0.10, 0, production.DisconnectReasonNormal},
		{"exactly hard threshold -> OOM", true, 0.90, 0, production.DisconnectReasonOOMSuspected},
		{"exactly inflight threshold with inflight -> OOM", true, 0.80, 1, production.DisconnectReasonOOMSuspected},
		{"just below inflight threshold with inflight -> normal", true, 0.80 - 0.01, 1, production.DisconnectReasonNormal},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := production.ClassifyDisconnectReason(tt.abrupt, tt.memoryPressure, tt.inFlight)
			if got != tt.want {
				t.Errorf("ClassifyDisconnectReason(%v, %.2f, %d) = %q, want %q",
					tt.abrupt, tt.memoryPressure, tt.inFlight, got, tt.want)
			}
		})
	}
}

// The accessor must read the last-known metrics + in-flight count atomically.
func TestProviderDisconnectDiagnostics(t *testing.T) {
	r := production.New(testLogger())
	p := r.Register("disconnect-diagnostics", nil, &protocol.RegisterMessage{})
	t.Cleanup(func() { r.Disconnect(p.ID) })
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.93}})
	p.AddPending(&production.PendingRequest{RequestID: "r1"})
	p.AddPending(&production.PendingRequest{RequestID: "r2"})

	mp, inFlight := p.DisconnectDiagnostics()
	if mp != 0.93 {
		t.Errorf("memoryPressure = %f, want 0.93", mp)
	}
	if inFlight != 2 {
		t.Errorf("inFlight = %d, want 2", inFlight)
	}
	if got := production.ClassifyDisconnectReason(true, mp, inFlight); got != production.DisconnectReasonOOMSuspected {
		t.Errorf("classify = %q, want oom_suspected", got)
	}
}
