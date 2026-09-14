package registry

import (
	"testing"
	"time"
)

func TestDisconnect(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	reg.Disconnect("p1")

	if reg.GetProvider("p1") != nil {
		t.Error("provider should be nil after disconnect")
	}
	if reg.ProviderCount() != 0 {
		t.Errorf("count = %d, want 0", reg.ProviderCount())
	}
}

func TestDisconnectUnknown(t *testing.T) {
	reg := New(testLogger())
	// Should not panic.
	reg.Disconnect("nonexistent")
}

func TestSetProviderIdle(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware
	p1.LastChallengeVerified = time.Now()
	p1.ChallengeVerifiedSIP = true

	// Put the provider in the serving state, then verify SetProviderIdle clears it.
	p := reg.GetProvider("p1")
	p.mu.Lock()
	p.Status = StatusServing
	p.mu.Unlock()
	if p.Status != StatusServing {
		t.Errorf("status = %q, want %q", p.Status, StatusServing)
	}

	reg.SetProviderIdle("p1")
	if p.Status != StatusOnline {
		t.Errorf("status = %q, want %q after idle", p.Status, StatusOnline)
	}
}

func TestSetProviderIdleDrainsQueue(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true

	// Mark provider as serving.
	findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")

	// Queue a request.
	qr := &QueuedRequest{
		RequestID:  "req-queued",
		Model:      "mlx-community/Qwen3.5-9B-Instruct-4bit",
		ResponseCh: make(chan *Provider, 1),
	}
	reg.Queue().Enqueue(qr)

	// Set provider idle — should drain queue and assign.
	reg.SetProviderIdle(p.ID)

	// The provider should have been assigned from the queue.
	select {
	case assigned := <-qr.ResponseCh:
		if assigned == nil {
			t.Fatal("expected non-nil provider from queue")
		}
		if assigned.ID != "p1" {
			t.Errorf("assigned provider = %q, want p1", assigned.ID)
		}
	case <-time.After(1 * time.Second):
		t.Error("timed out waiting for queue assignment")
	}
}
