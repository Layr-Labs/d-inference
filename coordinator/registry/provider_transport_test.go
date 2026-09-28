package registry

import (
	"context"
	"testing"
	"time"
)

func TestTransportMeasurementFreshnessAndForecast(t *testing.T) {
	now := time.Now()
	p := &Provider{}
	p.recordTransportLocked(100*time.Millisecond, now)
	if _, _, age := transportForecast(p.transport, now); age != -1 {
		t.Fatal("one sample qualified transport")
	}
	p.recordTransportLocked(300*time.Millisecond, now.Add(time.Second))
	expected, conservative, age := transportForecast(p.transport, now.Add(time.Second))
	if expected != 150 || conservative != 350 || age != 0 {
		t.Fatalf("forecast = %v/%v/%v", expected, conservative, age)
	}
	if _, _, age := transportForecast(p.transport, now.Add(2*time.Minute)); age != -1 {
		t.Fatal("stale transport retained")
	}
	c := measuredFirstContentCandidate(now)
	r := New(testLogger())
	pr := &PendingRequest{EstimatedPromptTokens: 100, FirstContentDeadline: now.Add(3 * time.Second)}
	r.estimateFirstContent(c, pr, now)
	before := c.firstContent
	c.snapshot.transportMs, c.snapshot.conservativeTransportMs = expected, conservative
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.ExpectedMs-before.ExpectedMs != expected || c.firstContent.ConservativeMs-before.ConservativeMs != conservative {
		t.Fatal("measured network term replaced delivery allowance or failed to reach forecast")
	}
}

func TestTransportRealWebSocketProbeAndDisconnect(t *testing.T) {
	h := newPingStallHarness(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	go func() { _, _, _ = h.clientConn.Read(ctx) }()
	p := &Provider{Conn: h.serverConn, Status: StatusOnline}
	for i := 0; i < 2; i++ {
		if err := p.MeasureTransport(ctx); err != nil {
			t.Fatalf("ping: %v", err)
		}
	}
	if p.transport.samples != 2 || p.transport.rtt <= 0 {
		t.Fatalf("no measured samples: %+v", p.transport)
	}
	p.modelIndexDetached = true
	p.transport = transportMeasurement{}
	if err := p.MeasureTransport(ctx); err != nil {
		t.Fatal(err)
	}
	if p.transport.samples != 0 {
		t.Fatal("detached session accepted a late probe")
	}
}

func TestMeasuredTransportChangesFirstContentSelection(t *testing.T) {
	now := time.Now()
	r := New(testLogger())
	pr := &PendingRequest{EstimatedPromptTokens: 1000, FirstContentDeadline: now.Add(10 * time.Second)}
	near, far := measuredFirstContentCandidate(now), measuredFirstContentCandidate(now)
	near.snapshot.transportMs = 20
	far.snapshot.transportMs = 250
	r.estimateFirstContent(near, pr, now)
	r.estimateFirstContent(far, pr, now)
	got, _, _, _ := selectFirstContentCandidate([]*routingCandidate{far, near}, "")
	if got != near {
		t.Fatal("measured network latency did not influence first-content ranking")
	}
	far.firstContentCachedTokens, far.firstContentCacheWeight = 1000, 1
	far.firstContentCacheExpiresAt = now.Add(time.Minute)
	r.estimateFirstContent(far, pr, now)
	got, _, _, _ = selectFirstContentCandidate([]*routingCandidate{far, near}, "")
	if got != far {
		t.Fatal("network preference erased useful cache locality")
	}
}
