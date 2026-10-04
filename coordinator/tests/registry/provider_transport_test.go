package registry_test

import (
	"context"
	"math/rand"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/transport"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
	"nhooyr.io/websocket"
)

func transportForecastEvidence(now time.Time) forecast.Evidence {
	return forecast.Evidence{
		Calibration: performance.CalibrationEvidence{
			HasCapacity: true, ModelLoaded: true, IsolatedPrefillTPS: 2000, IsolatedInitialized: true,
		},
		CapacityAcceptedAt: now, ObservedDecodeTPS: 100, PrefillTPS: 2000, DecodeTPS: 100,
		Workload: forecast.Workload{WholeMacKnown: true},
	}
}

func TestTransportMeasurementFreshnessAndForecast(t *testing.T) {
	now := time.Now()
	p := &transport.History{}
	p.Record(100*time.Millisecond, now)
	if _, _, age := p.Forecast(now); age != -1 {
		t.Fatal("one sample qualified transport")
	}
	p.Record(300*time.Millisecond, now.Add(time.Second))
	expected, conservative, age := p.Forecast(now.Add(time.Second))
	if expected != 150 || conservative != 350 || age != 0 {
		t.Fatalf("forecast = %v/%v/%v", expected, conservative, age)
	}
	beforeLate := *p
	p.Record(4*time.Second, now.Add(5*time.Second))
	if *p != beforeLate {
		t.Fatal("late pong changed accepted transport measurement")
	}
	if _, _, age := p.Forecast(now.Add(2 * time.Minute)); age != -1 {
		t.Fatal("stale transport retained")
	}
	c := transportForecastEvidence(now)
	pr := forecast.Request{PromptTokens: 100, UpperBoundTokens: 100, Deadline: now.Add(3 * time.Second)}
	before := forecast.Evaluate(c, pr, now).Estimate
	c.Transport.ExpectedMS, c.Transport.ConservativeMS = expected, conservative
	after := forecast.Evaluate(c, pr, now).Estimate
	if after.ExpectedMs-before.ExpectedMs != expected || after.ConservativeMs-before.ConservativeMs != conservative {
		t.Fatal("measured network term replaced delivery allowance or failed to reach forecast")
	}
}

func TestTransportRealWebSocketProbeAndDisconnect(t *testing.T) {
	serverConn, clientConn := testWebSocketPair(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	go func() { _, _, _ = clientConn.Read(ctx) }()
	go func() { _, _, _ = serverConn.Read(ctx) }()
	history := &transport.History{}
	r := production.NewWithDependencies(testLogger(), production.Dependencies{
		TransportMeasurements: func(string) *transport.History { return history },
	})
	// As in the original bare-provider fixture, the live probe socket has no
	// application writer. Disconnect can retire the session before its late pong.
	p := r.Register("transport", nil, testRegisterMessage())
	p.Conn, p.Status = serverConn, production.StatusOnline
	for i := 0; i < 2; i++ {
		if err := p.MeasureTransport(); err != nil {
			t.Fatalf("ping: %v", err)
		}
	}
	rtt, _, _ := history.Forecast(time.Now())
	if history.SampleCount() != 2 || rtt <= 0 {
		t.Fatalf("no measured samples: %+v", history)
	}
	r.Disconnect(p.ID)
	if err := p.MeasureTransport(); err != nil {
		t.Fatal(err)
	}
	if history.SampleCount() != 0 {
		t.Fatal("detached session accepted a late probe")
	}
}

func TestMeasuredTransportChangesFirstContentSelection(t *testing.T) {
	now := time.Now()
	pr := forecast.Request{PromptTokens: 1000, UpperBoundTokens: 1000, Deadline: now.Add(10 * time.Second)}
	nearEvidence, farEvidence := transportForecastEvidence(now), transportForecastEvidence(now)
	nearEvidence.Transport.ExpectedMS = 20
	farEvidence.Transport.ExpectedMS = 250
	near := &selection.Candidate{ExpectedMs: forecast.Evaluate(nearEvidence, pr, now).Estimate.ExpectedMs}
	far := &selection.Candidate{ExpectedMs: forecast.Evaluate(farEvidence, pr, now).Estimate.ExpectedMs}
	pool := []*selection.Candidate{far, near}
	project := func(c *selection.Candidate) selection.Candidate { return *c }
	got := pool[selection.Select(pool, project, rand.Intn, "").Winner]
	if got != near {
		t.Fatal("measured network latency did not influence first-content ranking")
	}
	benefit := forecast.CacheBenefit{Tokens: 1000, Weight: 1, ExpiresAt: now.Add(time.Minute)}
	benefit.Apply(&pr, now)
	far.CachedTokens, far.CacheEvidenceWeight = pr.CachedTokens, benefit.Weight
	far.ExpectedMs = forecast.Evaluate(farEvidence, pr, now).Estimate.ExpectedMs
	got = pool[selection.Select(pool, project, rand.Intn, "").Winner]
	if got != far {
		t.Fatal("network preference erased useful cache locality")
	}
}

func TestTransportUnansweredPongWaitsForConnectionTeardown(t *testing.T) {
	h := newPingStallHarness(t)
	r := production.New(testLogger())
	p := r.Register("transport-session", h.serverConn, &protocol.RegisterMessage{})
	done := make(chan error, 1)
	go func() { done <- p.MeasureTransport() }()

	// No client Read means no automatic pong. The observation acceptance limit
	// must not become a socket deadline or launch another probe while this waits.
	select {
	case err := <-done:
		t.Fatalf("unanswered pong ended before connection teardown: %v", err)
	case <-time.After(3250 * time.Millisecond):
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := h.clientConn.Write(ctx, websocket.MessageText, []byte("still alive")); err != nil {
		t.Fatalf("unanswered transport probe closed the connection: %v", err)
	}
	select {
	case message := <-h.inbound:
		if message != "still alive" {
			t.Fatalf("unexpected application message: %q", message)
		}
	case <-ctx.Done():
		t.Fatal("transport observer blocked the application read loop")
	}

	// The real registry disconnect owns socket closure and must release the
	// outstanding observer without waiting for another pong or timer tick.
	r.Disconnect(p.ID)
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("unanswered ping succeeded after disconnect")
		}
	case <-time.After(time.Second):
		t.Fatal("connection teardown retained transport observer")
	}
}
