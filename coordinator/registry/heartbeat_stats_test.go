package registry

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestHeartbeatAccumulatesUptime is the integration regression: the
// heartbeat handler credits the wall-clock gap since the previous heartbeat as
// uptime (bounded), so an always-online provider's reputation can exceed 0.85.
// This test fails without the Heartbeat inventory update.
func TestHeartbeatAccumulatesUptime(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	// Simulate ~45s since the last heartbeat (within the 2m credit window).
	p.mu.Lock()
	p.LastHeartbeat = time.Now().Add(-45 * time.Second)
	p.mu.Unlock()

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})

	p.mu.Lock()
	credited := p.Reputation.TotalUptime
	p.mu.Unlock()
	if credited < 40*time.Second || credited > 50*time.Second {
		t.Fatalf("uptime credited = %v, want ~45s", credited)
	}

	// An oversized gap (provider effectively offline) must NOT be credited.
	p.mu.Lock()
	p.LastHeartbeat = time.Now().Add(-30 * time.Minute)
	before := p.Reputation.TotalUptime
	p.mu.Unlock()

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "idle"})

	p.mu.Lock()
	after := p.Reputation.TotalUptime
	p.mu.Unlock()
	if jump := after - before; jump > time.Minute {
		t.Fatalf("oversized offline gap credited %v of uptime, want it skipped", jump)
	}

	// After enough accumulated uptime + a perfect record, the score must clear
	// the old 0.85 cap.
	p.mu.Lock()
	p.Reputation.RecordUptime(24 * time.Hour)
	p.Reputation.RecordJobSuccess()
	p.Reputation.RecordLatency(300 * time.Millisecond)
	p.Reputation.RecordChallengePass()
	score := p.Reputation.Score()
	p.mu.Unlock()
	if score <= 0.85 {
		t.Fatalf("score = %f, want > 0.85 after accumulated uptime", score)
	}
}

func TestHeartbeatAccumulatesAcrossRestarts(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	lifetimeStats := protocol.HeartbeatStats{
		RequestsServed:               100,
		TokensGenerated:              2000,
		CancellationsReceived:        7,
		CancellationsBeforeOutput:    3,
		CancellationsPartialComplete: 2,
		GenerationErrorsAfterOutput:  4,
		ChunkEncryptionErrors:        1,
		StreamClosedWithoutTerminal:  5,
		CancelDuringModelLoad:        6,
		UsageGaps:                    8,
	}
	lastSessionStats := lifetimeStats
	lifetimeJSON, _ := json.Marshal(lifetimeStats)
	lastSessionJSON, _ := json.Marshal(lastSessionStats)
	if err := reg.RestoreProviderState(p, &store.ProviderRecord{
		ID:                         "persisted-p1",
		TrustLevel:                 string(TrustHardware),
		Attested:                   true,
		LifetimeRequestsServed:     100,
		LifetimeTokensGenerated:    2000,
		LastSessionRequestsServed:  100,
		LastSessionTokensGenerated: 2000,
		LifetimeStats:              lifetimeJSON,
		LastSessionStats:           lastSessionJSON,
	}); err != nil {
		t.Fatal(err)
	}

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{RequestsServed: 100, TokensGenerated: 2000},
	})

	if p.Stats.RequestsServed != 100 {
		t.Fatalf("requests_served after coordinator restart = %d, want 100", p.Stats.RequestsServed)
	}
	if p.Stats.TokensGenerated != 2000 {
		t.Fatalf("tokens_generated after coordinator restart = %d, want 2000", p.Stats.TokensGenerated)
	}
	if p.Stats.CancellationsReceived != 7 || p.Stats.UsageGaps != 8 {
		t.Fatalf("restored outcome counters = %+v, want persisted heartbeat stats", p.Stats)
	}

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats: protocol.HeartbeatStats{
			RequestsServed:        105,
			TokensGenerated:       2300,
			CancellationsReceived: 9,
			UsageGaps:             11,
		},
	})

	if p.Stats.RequestsServed != 105 {
		t.Fatalf("requests_served after new work = %d, want 105", p.Stats.RequestsServed)
	}
	if p.Stats.TokensGenerated != 2300 {
		t.Fatalf("tokens_generated after new work = %d, want 2300", p.Stats.TokensGenerated)
	}
	if p.Stats.CancellationsReceived != 9 || p.Stats.UsageGaps != 11 {
		t.Fatalf("outcome counters after new work = %+v, want updated counters", p.Stats)
	}

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats: protocol.HeartbeatStats{
			RequestsServed:        2,
			TokensGenerated:       40,
			CancellationsReceived: 1,
			UsageGaps:             1,
		},
	})

	if p.Stats.RequestsServed != 107 {
		t.Fatalf("requests_served after provider restart = %d, want 107", p.Stats.RequestsServed)
	}
	if p.Stats.TokensGenerated != 2340 {
		t.Fatalf("tokens_generated after provider restart = %d, want 2340", p.Stats.TokensGenerated)
	}
	if p.Stats.CancellationsReceived != 10 || p.Stats.UsageGaps != 12 {
		t.Fatalf("outcome counters after provider restart = %+v, want accumulated counters", p.Stats)
	}
}
