package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestRecordJobSuccessUpdatesReputation(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	reg.RecordJobSuccess("p1", 500*time.Millisecond)
	reg.RecordJobSuccess("p1", 500*time.Millisecond)

	if p.Reputation.SuccessfulJobs != 2 {
		t.Errorf("successful_jobs = %d, want 2", p.Reputation.SuccessfulJobs)
	}
	if p.Reputation.TotalJobs != 2 {
		t.Errorf("total_jobs = %d, want 2", p.Reputation.TotalJobs)
	}
	// Both calls fed a 500ms TTFT: seed 500ms then EWMA stays 500ms.
	if p.Reputation.AvgResponseTime != 500*time.Millisecond {
		t.Errorf("avg_response_time = %v, want 500ms", p.Reputation.AvgResponseTime)
	}
}

// TestRecordJobSuccessLatencyEWMA exercises the Registry wrapper end-to-end: the
// real TTFT passed to RecordJobSuccess is folded into the provider's
// AvgResponseTime EWMA, and a non-positive TTFT records the job without
// touching latency.
func TestRecordJobSuccessLatencyEWMA(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	reg.RecordJobSuccess("p1", 100*time.Millisecond) // seed
	if got := p.Reputation.AvgResponseTime; got != 100*time.Millisecond {
		t.Fatalf("after seed: avg = %v, want 100ms", got)
	}
	reg.RecordJobSuccess("p1", 200*time.Millisecond) // 100*0.8 + 200*0.2 = 120ms
	if got := p.Reputation.AvgResponseTime; got != 120*time.Millisecond {
		t.Fatalf("after EWMA: avg = %v, want 120ms", got)
	}

	// A zero TTFT (no first-chunk timestamp) still counts the job but leaves
	// the latency average unchanged.
	reg.RecordJobSuccess("p1", 0)
	if got := p.Reputation.AvgResponseTime; got != 120*time.Millisecond {
		t.Fatalf("after zero ttft: avg = %v, want unchanged 120ms", got)
	}
	if p.Reputation.SuccessfulJobs != 3 {
		t.Errorf("successful_jobs = %d, want 3", p.Reputation.SuccessfulJobs)
	}
}

func TestRecordJobFailureUpdatesReputation(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	reg.RecordJobFailure("p1")

	if p.Reputation.FailedJobs != 1 {
		t.Errorf("failed_jobs = %d, want 1", p.Reputation.FailedJobs)
	}
	if p.Reputation.TotalJobs != 1 {
		t.Errorf("total_jobs = %d, want 1", p.Reputation.TotalJobs)
	}
}

func TestBenchmarkFieldsInRegistration(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	msg.PrefillTPS = 500.0
	msg.DecodeTPS = 100.0

	p := reg.Register("p1", nil, msg)
	if p.PrefillTPS != 500.0 {
		t.Errorf("prefill_tps = %f, want 500.0", p.PrefillTPS)
	}
	if p.DecodeTPS != 100.0 {
		t.Errorf("decode_tps = %f, want 100.0", p.DecodeTPS)
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

func TestPendingRequests(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	pr := &PendingRequest{
		RequestID:  "req-1",
		ChunkCh:    make(chan string, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
	}
	p.AddPending(pr)

	if p.PendingCount() != 1 {
		t.Errorf("pending count = %d, want 1", p.PendingCount())
	}

	got := p.GetPending("req-1")
	if got == nil {
		t.Fatal("GetPending returned nil")
	}
	if got.RequestID != "req-1" {
		t.Errorf("request_id = %q", got.RequestID)
	}

	removed := p.RemovePending("req-1")
	if removed == nil {
		t.Fatal("RemovePending returned nil")
	}
	if p.PendingCount() != 0 {
		t.Errorf("pending count after remove = %d", p.PendingCount())
	}
}
