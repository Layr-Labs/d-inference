package api

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Gate G5 (v0.8.0 paged rollout): the coordinator must be able to segment
// TTFT / decode-TPS / error-rate by KV backend. These tests drive the REAL
// emission paths against a REAL DogStatsD client over a local UDP collector,
// so deleting a tag or an emit fails here rather than silently producing an
// un-segmentable dashboard.
//
// The load-bearing property throughout: a pre-0.8.0 provider that omits
// kv_backend must land in its OWN population, never fold into contiguous.

// kvMetricsFleet is one (provider, model, backend) row of a mixed fleet.
type kvMetricsFleet struct {
	providerID string
	model      string
	// backend is the value the provider heartbeats; nil reproduces a pre-0.8.0
	// provider that omits the key entirely.
	backend *string
	wantTag string
}

// registerHeartbeatedProvider registers a provider and drives ONE real
// heartbeat carrying the slot's kv_backend, so the test exercises the ingest
// path rather than hand-setting registry state.
func registerHeartbeatedProvider(t *testing.T, srv *Server, id, model string, backend *string) *registry.Provider {
	t.Helper()
	p := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	if p == nil {
		t.Fatalf("provider %q did not register", id)
	}
	srv.registry.Heartbeat(id, &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{
				{Model: model, State: "running", KVBackend: backend},
			},
		},
	})
	return p
}

// completedPendingRequest builds a pending request whose Timing yields a
// positive actual_ttft_ms and a measurable decode window, reserves its cost,
// and registers it on the provider so handleComplete settles it normally.
func completedPendingRequest(t *testing.T, srv *Server, p *registry.Provider, reqID, model string, usage protocol.UsageInfo) *registry.PendingRequest {
	t.Helper()
	cost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	if err := srv.ledger.Charge(testConsumerID, cost, "reserve:"+reqID); err != nil {
		t.Fatalf("reserve balance for %s: %v", reqID, err)
	}
	base := time.Now().Add(-2 * time.Second)
	pr := &registry.PendingRequest{
		RequestID:        reqID,
		ProviderID:       p.ID,
		Model:            model,
		ConsumerKey:      testConsumerID,
		ReservedMicroUSD: cost,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
		Timing: &registry.RequestTiming{
			ReceivedAt:     base.Add(-50 * time.Millisecond),
			DispatchedAt:   base,
			FirstChunkAt:   base.Add(100 * time.Millisecond),
			FirstContentAt: base.Add(250 * time.Millisecond),
		},
	}
	p.AddPending(pr)
	return pr
}

// tagCount counts packets for metric that carry tag.
func tagCount(packets []string, metric, tag string) int {
	n := 0
	for _, p := range packets {
		if strings.Contains(p, metric) && strings.Contains(p, tag) {
			n++
		}
	}
	return n
}

// TestMixedFleetCompletionMetricsSeparateThreePopulations drives one completion
// on each of a paged slot, a contiguous slot and a pre-0.8.0 slot that omits
// kv_backend, then proves the three populations are separable in the emitted
// TTFT and decode-TPS histograms with no cross-contamination.
//
// The counts are exact, not "at least one". That is what makes the test fail if
// an absent kv_backend is ever coerced to a default: folding unknown into
// contiguous would make kv_backend:contiguous 2 instead of 1.
func TestMixedFleetCompletionMetricsSeparateThreePopulations(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	paged, contiguous := registry.KVBackendPaged, registry.KVBackendContiguous
	fleet := []kvMetricsFleet{
		{"g5-box-paged", model, &paged, registry.KVBackendPaged},
		{"g5-box-contiguous", model, &contiguous, registry.KVBackendContiguous},
		// Pre-0.8.0: reports the slot, omits kv_backend.
		{"g5-box-pre-080", model, nil, registry.KVBackendUnknown},
	}

	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
	for _, row := range fleet {
		p := registerHeartbeatedProvider(t, srv, row.providerID, row.model, row.backend)
		pr := completedPendingRequest(t, srv, p, "g5-"+row.providerID, row.model, usage)
		srv.handleComplete(p.ID, p, &protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: pr.RequestID,
			Usage:     usage,
		})
	}

	_ = dd.Statsd.Flush()
	packets := collector.drain()

	for _, metric := range []string{metricRequestTTFT, metricRequestDecodeTPS} {
		samples := findMetrics(packets, metric)
		if len(samples) != len(fleet) {
			t.Fatalf("%s: got %d samples, want %d (one per completion); packets=%v",
				metric, len(samples), len(fleet), packets)
		}
		for _, row := range fleet {
			tag := kvBackendTagKey + row.wantTag
			if got := tagCount(samples, metric, tag); got != 1 {
				t.Errorf("%s{%s}: got %d samples, want exactly 1; samples=%v",
					metric, tag, got, samples)
			}
		}
		// No population may leak into a backend the fleet never reported.
		for _, absent := range []string{registry.KVBackendOther, registry.KVBackendUnspecified} {
			if got := tagCount(samples, metric, kvBackendTagKey+absent); got != 0 {
				t.Errorf("%s{kv_backend:%s}: got %d samples, want 0", metric, absent, got)
			}
		}
	}

	// Stated separately so the intent survives a refactor of the loop above:
	// the pre-0.8.0 completion must not have been booked as a contiguous sample.
	if got := tagCount(packets, metricRequestTTFT, kvBackendTagKey+registry.KVBackendContiguous); got != 1 {
		t.Fatalf("kv_backend:contiguous TTFT samples = %d, want exactly 1 — a second one means the "+
			"pre-0.8.0 provider was silently coerced to contiguous", got)
	}
	if got := tagCount(packets, metricRequestTTFT, kvBackendTagKey+registry.KVBackendUnknown); got != 1 {
		t.Fatalf("kv_backend:unknown TTFT samples = %d, want exactly 1 — the pre-0.8.0 provider must "+
			"form its own population", got)
	}
}

// TestOneProviderTwoModelsAttributesEachToItsOwnBackend is the staged-rollout
// case: one box holding two models, one paged and one contiguous. Attribution
// follows the SLOT, so each request must carry its own model's backend.
// Provider-granularity attribution would give both requests the same tag.
func TestOneProviderTwoModelsAttributesEachToItsOwnBackend(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	const (
		providerID      = "g5-box-two-models"
		pagedModel      = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
		contiguousModel = "mlx-community/gpt-oss-20b"
	)
	p := srv.registry.Register(providerID, nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{
			{ID: pagedModel, ModelType: "chat", Quantization: "4bit"},
			{ID: contiguousModel, ModelType: "chat", Quantization: "4bit"},
		},
	})
	paged, contiguous := registry.KVBackendPaged, registry.KVBackendContiguous
	srv.registry.Heartbeat(providerID, &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "serving",
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 128,
			Slots: []protocol.BackendSlotCapacity{
				{Model: pagedModel, State: "running", KVBackend: &paged},
				{Model: contiguousModel, State: "running", KVBackend: &contiguous},
			},
		},
	})

	usage := protocol.UsageInfo{PromptTokens: 800, CompletionTokens: 200}
	for _, model := range []string{pagedModel, contiguousModel} {
		pr := completedPendingRequest(t, srv, p, "g5-two-models-"+model, model, usage)
		srv.handleComplete(p.ID, p, &protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: pr.RequestID,
			Usage:     usage,
		})
	}

	_ = dd.Statsd.Flush()
	packets := findMetrics(collector.drain(), metricRequestTTFT)
	if len(packets) != 2 {
		t.Fatalf("got %d TTFT samples, want 2; packets=%v", len(packets), packets)
	}

	for _, tc := range []struct{ model, wantBackend, wrongBackend string }{
		{pagedModel, registry.KVBackendPaged, registry.KVBackendContiguous},
		{contiguousModel, registry.KVBackendContiguous, registry.KVBackendPaged},
	} {
		var found string
		for _, p := range packets {
			if strings.Contains(p, "model:"+tc.model) {
				found = p
			}
		}
		if found == "" {
			t.Fatalf("no TTFT sample for model %s; packets=%v", tc.model, packets)
		}
		if !strings.Contains(found, kvBackendTagKey+tc.wantBackend) {
			t.Errorf("model %s tagged %q, want kv_backend:%s", tc.model, found, tc.wantBackend)
		}
		if strings.Contains(found, kvBackendTagKey+tc.wrongBackend) {
			t.Errorf("model %s picked up the co-resident slot's backend %s: %q",
				tc.model, tc.wrongBackend, found)
		}
	}
}

// TestRequestOutcomeSegmentsByServingSlotBackend covers the error/503 half of
// the gate. inference.request_outcome carries both the numerator and the
// denominator of the OR-uptime formula, so tagging it segments the error RATE,
// not just the error count.
//
// It reproduces the exhaustion ladder's exact sequence — dispatch to a slot,
// failover clears d.provider/d.pr, then emit — because that is where a
// dispatched-but-failed request is counted, and it is the sample a paged
// regression shows up in first.
func TestRequestOutcomeSegmentsByServingSlotBackend(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	paged, contiguous := registry.KVBackendPaged, registry.KVBackendContiguous
	fleet := []kvMetricsFleet{
		{"g5-outcome-paged", model, &paged, registry.KVBackendPaged},
		{"g5-outcome-contiguous", model, &contiguous, registry.KVBackendContiguous},
		{"g5-outcome-pre-080", model, nil, registry.KVBackendUnknown},
	}

	for _, row := range fleet {
		p := registerHeartbeatedProvider(t, srv, row.providerID, row.model, row.backend)
		d := &dispatchState{
			s:     srv,
			model: row.model,
			pr:    &registry.PendingRequest{RequestID: "req-" + row.providerID, ProviderID: p.ID, Model: row.model},
		}
		d.noteServingSlot()
		// Every failover path clears these before the exhaustion ladder runs.
		d.provider, d.pr = nil, nil
		srv.recordRequestOutcome(d.model, d.kvBackendAttribution(), orClassProvider5xx)
	}

	// A pre-dispatch rejection never reached a slot: unattributable, and it must
	// say so rather than borrow a backend.
	srv.recordRequestOutcome(model, kvBackendAttribution{}, orClassRateLimited)

	_ = dd.Statsd.Flush()
	outcomes := findMetrics(collector.drain(), metricRequestOutcome)
	if len(outcomes) != len(fleet)+1 {
		t.Fatalf("got %d request_outcome samples, want %d; samples=%v", len(outcomes), len(fleet)+1, outcomes)
	}

	for _, row := range fleet {
		want := kvBackendTagKey + row.wantTag
		n := 0
		for _, p := range outcomes {
			if strings.Contains(p, want) && strings.Contains(p, "class:"+orClassProvider5xx) {
				n++
			}
		}
		if n != 1 {
			t.Errorf("request_outcome{%s,class:%s}: got %d, want 1; samples=%v",
				want, orClassProvider5xx, n, outcomes)
		}
	}
	if got := tagCount(outcomes, metricRequestOutcome, kvBackendTagKey+registry.KVBackendContiguous); got != 1 {
		t.Fatalf("kv_backend:contiguous outcomes = %d, want exactly 1 — an absent kv_backend was coerced", got)
	}
	// The pre-dispatch rejection plus the pre-0.8.0 provider's 5xx: two unknowns,
	// and the rejection is the rate_limited one.
	if got := tagCount(outcomes, metricRequestOutcome, kvBackendTagKey+registry.KVBackendUnknown); got != 2 {
		t.Fatalf("kv_backend:unknown outcomes = %d, want 2; samples=%v", got, outcomes)
	}
	for _, p := range outcomes {
		if strings.Contains(p, "class:"+orClassRateLimited) &&
			!strings.Contains(p, kvBackendTagKey+registry.KVBackendUnknown) {
			t.Errorf("pre-dispatch rejection must be kv_backend:unknown, got %q", p)
		}
	}
}

// TestDispatchKVBackendTagFollowsTheServingSlot pins the two behaviours of the
// dispatch-side resolver: the latch survives a failover clearing d.pr (the
// exhaustion ladder still attributes the failure), and a live d.pr WINS over
// the latch (a speculative backup that takes over is attributed to the backup's
// slot, not the primary's).
func TestDispatchKVBackendTagFollowsTheServingSlot(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	paged, contiguous := registry.KVBackendPaged, registry.KVBackendContiguous
	primary := registerHeartbeatedProvider(t, srv, "g5-latch-primary", model, &paged)
	backup := registerHeartbeatedProvider(t, srv, "g5-latch-backup", model, &contiguous)

	d := &dispatchState{s: srv, model: model}
	// Never reached a slot yet.
	if got := d.kvBackendAttribution().Backend; got != registry.KVBackendUnknown {
		t.Fatalf("before dispatch = %q, want %q", got, registry.KVBackendUnknown)
	}

	d.pr = &registry.PendingRequest{RequestID: "req-latch", ProviderID: primary.ID, Model: model}
	d.noteServingSlot()
	d.pr = nil
	if got := d.kvBackendAttribution().Backend; got != registry.KVBackendPaged {
		t.Errorf("after failover cleared d.pr = %q, want %q (the latch is what keeps a crashed "+
			"paged slot's 5xx attributable)", got, registry.KVBackendPaged)
	}

	// Speculative backup takes over: the live pending request wins.
	d.pr = &registry.PendingRequest{RequestID: "req-latch-backup", ProviderID: backup.ID, Model: model}
	if got := d.kvBackendAttribution().Backend; got != registry.KVBackendContiguous {
		t.Errorf("after a backup win = %q, want %q", got, registry.KVBackendContiguous)
	}
}

// A slot torn down between dispatch and completion (OOM, crash, eviction)
// disappears from the provider's heartbeat entirely. Its request must still be
// attributed to the backend it ran on — that failure is the whole point of the
// gate.
func TestCompletionMetricsSurviveSlotTeardown(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	paged := registry.KVBackendPaged
	p := registerHeartbeatedProvider(t, srv, "g5-box-torn-down", model, &paged)

	usage := protocol.UsageInfo{PromptTokens: 400, CompletionTokens: 120}
	pr := completedPendingRequest(t, srv, p, "g5-torn-down", model, usage)

	// The slot is gone from the next heartbeat.
	srv.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Type:            protocol.TypeHeartbeat,
		Status:          "serving",
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64},
	})

	srv.handleComplete(p.ID, p, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	})
	_ = dd.Statsd.Flush()
	samples := findMetrics(collector.drain(), metricRequestTTFT)
	if len(samples) != 1 {
		t.Fatalf("got %d TTFT samples, want 1; samples=%v", len(samples), samples)
	}
	if !strings.Contains(samples[0], kvBackendTagKey+registry.KVBackendPaged) {
		t.Errorf("torn-down paged slot lost its attribution: %q", samples[0])
	}
}

// Metric-name and tag-shape contract, and nil-safety when Datadog is not wired.
func TestBackendMetricNamesAndSampleGuards(t *testing.T) {
	if metricRequestTTFT != "inference.ttft_ms" {
		t.Errorf("metricRequestTTFT = %q", metricRequestTTFT)
	}
	if metricRequestDecodeTPS != "inference.decode_tps" {
		t.Errorf("metricRequestDecodeTPS = %q", metricRequestDecodeTPS)
	}
	if kvBackendTagKey != "kv_backend:" {
		t.Errorf("kvBackendTagKey = %q; must match the heartbeat wire key", kvBackendTagKey)
	}
	if kvBackendFallbackTagKey != "kv_backend_fallback:" {
		t.Errorf("kvBackendFallbackTagKey = %q; must match the heartbeat wire key", kvBackendFallbackTagKey)
	}
	if got := normalizeKVBackendTag(""); got != registry.KVBackendUnknown {
		t.Errorf("normalizeKVBackendTag(\"\") = %q, want %q", got, registry.KVBackendUnknown)
	}
	// "" is UNKNOWN here too, never "none": a call site with no serving slot
	// has established nothing about whether a slot degraded.
	if got := normalizeKVBackendFallbackTag(""); got != registry.KVFallbackUnknown {
		t.Errorf("normalizeKVBackendFallbackTag(\"\") = %q, want %q", got, registry.KVFallbackUnknown)
	}
	for _, bad := range []float64{0, -1} {
		if usableMetricSample(bad) {
			t.Errorf("usableMetricSample(%v) = true, want false", bad)
		}
	}

	// No Datadog client configured: helpers must not panic.
	srv, _, _ := billingTestServer(t)
	srv.emitRequestBackendLatency("m", kvBackendAttribution{Backend: registry.KVBackendPaged}, 12, 34)
	if got := srv.kvBackendAttribution("no-such-provider", "m"); got.Backend != registry.KVBackendUnknown ||
		got.Fallback != registry.KVFallbackUnknown {
		t.Errorf("attribution for an unknown provider = %+v", got)
	}
}

// An unmeasurable request records no sample at all. A zero would be a real
// data point at the floor of the histogram and would drag the p90 the rollout
// is judged on.
func TestUnmeasurableRequestEmitsNoBackendSample(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	srv.emitRequestBackendLatency("m", kvBackendAttribution{Backend: registry.KVBackendPaged}, 0, 0)
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if hasMetric(packets, metricRequestTTFT) || hasMetric(packets, metricRequestDecodeTPS) {
		t.Errorf("zero-valued samples must not be emitted; packets=%v", packets)
	}
}
