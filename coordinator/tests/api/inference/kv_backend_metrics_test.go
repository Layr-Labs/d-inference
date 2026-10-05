package inference_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// kvMetricsFleet is one (provider, model, backend) row of a mixed fleet.
type kvMetricsFleet struct {
	providerID string
	model      string
	// backend is the value the provider heartbeats; nil reproduces a pre-0.8.0
	// provider that omits the key entirely.
	backend *string
	wantTag string
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
	srv.observation.SetDatadog(dd)

	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	paged, contiguous := registry.KVBackendPaged, registry.KVBackendContiguous
	fleet := []kvMetricsFleet{
		{"g5-box-paged", model, &paged, registry.KVBackendPaged},
		{"g5-box-contiguous", model, &contiguous, registry.KVBackendContiguous},

		{"g5-box-pre-080", model, nil, registry.KVBackendUnknown},
	}

	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
	for _, row := range fleet {
		p := registerHeartbeatedProvider(t, srv, row.providerID, row.model, row.backend)
		pr := completedPendingRequest(t, srv, p, "g5-"+row.providerID, row.model, usage)
		srv.HandleCompleteAt(p.ID, p, &protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: pr.RequestID,
			Usage:     usage,
		}, time.Now())
	}

	_ = dd.Statsd.Flush()
	packets := collector.drain()

	for _, metric := range []string{infermetrics.RequestTTFT, infermetrics.RequestDecodeTPS} {
		samples := findMetrics(packets, metric)
		if len(samples) != len(fleet) {
			t.Fatalf("%s: got %d samples, want %d (one per completion); packets=%v",
				metric, len(samples), len(fleet), packets)
		}
		for _, row := range fleet {
			tag := backend.TagKey + row.wantTag
			if got := tagCount(samples, metric, tag); got != 1 {
				t.Errorf("%s{%s}: got %d samples, want exactly 1; samples=%v",
					metric, tag, got, samples)
			}
		}

		for _, absent := range []string{registry.KVBackendOther, registry.KVBackendUnspecified} {
			if got := tagCount(samples, metric, backend.TagKey+absent); got != 0 {
				t.Errorf("%s{kv_backend:%s}: got %d samples, want 0", metric, absent, got)
			}
		}
	}

	if got := tagCount(packets, infermetrics.RequestTTFT, backend.TagKey+registry.KVBackendContiguous); got != 1 {
		t.Fatalf("kv_backend:contiguous TTFT samples = %d, want exactly 1 — a second one means the "+
			"pre-0.8.0 provider was silently coerced to contiguous", got)
	}
	if got := tagCount(packets, infermetrics.RequestTTFT, backend.TagKey+registry.KVBackendUnknown); got != 1 {
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
	srv.observation.SetDatadog(dd)

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
		srv.HandleCompleteAt(p.ID, p, &protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: pr.RequestID,
			Usage:     usage,
		}, time.Now())
	}

	_ = dd.Statsd.Flush()
	packets := findMetrics(collector.drain(), infermetrics.RequestTTFT)
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
		if !strings.Contains(found, backend.TagKey+tc.wantBackend) {
			t.Errorf("model %s tagged %q, want kv_backend:%s", tc.model, found, tc.wantBackend)
		}
		if strings.Contains(found, backend.TagKey+tc.wrongBackend) {
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
	srv.observation.SetDatadog(dd)

	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	paged, contiguous := registry.KVBackendPaged, registry.KVBackendContiguous
	fleet := []kvMetricsFleet{
		{"g5-outcome-paged", model, &paged, registry.KVBackendPaged},
		{"g5-outcome-contiguous", model, &contiguous, registry.KVBackendContiguous},
		{"g5-outcome-pre-080", model, nil, registry.KVBackendUnknown},
	}

	for _, row := range fleet {
		p := registerHeartbeatedProvider(t, srv, row.providerID, row.model, row.backend)
		latch := srv.NewBackendLatch()
		pending := &registry.PendingRequest{RequestID: "req-" + row.providerID, ProviderID: p.ID, Model: row.model}
		latch.Note(p, pending, false)

		p, pending = nil, nil
		srv.NewMetrics().BackendOutcome(row.model, latch.Resolve(pending, false, false), infermetrics.ORProvider5xx)
	}

	srv.NewMetrics().BackendOutcome(model, backend.Unknown(), infermetrics.ORRateLimited)

	_ = dd.Statsd.Flush()
	outcomes := findMetrics(collector.drain(), infermetrics.RequestOutcomeMetric)
	if len(outcomes) != len(fleet)+1 {
		t.Fatalf("got %d request_outcome samples, want %d; samples=%v", len(outcomes), len(fleet)+1, outcomes)
	}

	for _, row := range fleet {
		want := backend.TagKey + row.wantTag
		n := 0
		for _, p := range outcomes {
			if strings.Contains(p, want) && strings.Contains(p, "class:"+infermetrics.ORProvider5xx) {
				n++
			}
		}
		if n != 1 {
			t.Errorf("request_outcome{%s,class:%s}: got %d, want 1; samples=%v",
				want, infermetrics.ORProvider5xx, n, outcomes)
		}
	}
	if got := tagCount(outcomes, infermetrics.RequestOutcomeMetric, backend.TagKey+registry.KVBackendContiguous); got != 1 {
		t.Fatalf("kv_backend:contiguous outcomes = %d, want exactly 1 — an absent kv_backend was coerced", got)
	}

	if got := tagCount(outcomes, infermetrics.RequestOutcomeMetric, backend.TagKey+registry.KVBackendUnknown); got != 2 {
		t.Fatalf("kv_backend:unknown outcomes = %d, want 2; samples=%v", got, outcomes)
	}

	for _, p := range outcomes {
		for _, key := range []string{backend.TagKey, backend.FallbackTagKey} {
			if strings.Contains(p, key+",") || strings.HasSuffix(p, key) {
				t.Errorf("empty %s dimension in %q", key, p)
			}
		}
	}
	for _, p := range outcomes {
		if strings.Contains(p, "class:"+infermetrics.ORRateLimited) &&
			!strings.Contains(p, backend.TagKey+registry.KVBackendUnknown) {
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

	latch := srv.NewBackendLatch()

	if got := latch.Resolve(nil, false, false).Backend; got != registry.KVBackendUnknown {
		t.Fatalf("before dispatch = %q, want %q", got, registry.KVBackendUnknown)
	}

	pending := &registry.PendingRequest{RequestID: "req-latch", ProviderID: primary.ID, Model: model}
	latch.Note(primary, pending, false)
	pending = nil
	if got := latch.Resolve(pending, false, false).Backend; got != registry.KVBackendPaged {
		t.Errorf("after failover cleared d.pr = %q, want %q (the latch is what keeps a crashed "+
			"paged slot's 5xx attributable)", got, registry.KVBackendPaged)
	}

	pending = &registry.PendingRequest{RequestID: "req-latch-backup", ProviderID: backup.ID, Model: model}
	if got := latch.Resolve(pending, false, false).Backend; got != registry.KVBackendContiguous {
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
	srv.observation.SetDatadog(dd)

	const model = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	paged := registry.KVBackendPaged
	p := registerHeartbeatedProvider(t, srv, "g5-box-torn-down", model, &paged)

	usage := protocol.UsageInfo{PromptTokens: 400, CompletionTokens: 120}
	pr := completedPendingRequest(t, srv, p, "g5-torn-down", model, usage)

	srv.registry.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Type:            protocol.TypeHeartbeat,
		Status:          "serving",
		BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64},
	})

	srv.HandleCompleteAt(p.ID, p, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	}, time.Now())
	_ = dd.Statsd.Flush()
	samples := findMetrics(collector.drain(), infermetrics.RequestTTFT)
	if len(samples) != 1 {
		t.Fatalf("got %d TTFT samples, want 1; samples=%v", len(samples), samples)
	}
	if !strings.Contains(samples[0], backend.TagKey+registry.KVBackendPaged) {
		t.Errorf("torn-down paged slot lost its attribution: %q", samples[0])
	}
}

// Metric-name and tag-shape contract, and nil-safety when Datadog is not wired.
func TestBackendMetricNamesAndSampleGuards(t *testing.T) {
	if infermetrics.RequestTTFT != "inference.ttft_ms" {
		t.Errorf("metricRequestTTFT = %q", infermetrics.RequestTTFT)
	}
	if infermetrics.RequestDecodeTPS != "inference.decode_tps" {
		t.Errorf("metricRequestDecodeTPS = %q", infermetrics.RequestDecodeTPS)
	}
	if backend.TagKey != "kv_backend:" {
		t.Errorf("kvBackendTagKey = %q; must match the heartbeat wire key", backend.TagKey)
	}
	if backend.FallbackTagKey != "kv_backend_fallback:" {
		t.Errorf("kvBackendFallbackTagKey = %q; must match the heartbeat wire key", backend.FallbackTagKey)
	}

	unknown := backend.Unknown()
	if unknown.Backend != registry.KVBackendUnknown {
		t.Errorf("unknown attribution backend = %q, want %q", unknown.Backend, registry.KVBackendUnknown)
	}

	if unknown.Fallback != registry.KVFallbackUnknown {
		t.Errorf("unknown attribution fallback = %q, want %q", unknown.Fallback, registry.KVFallbackUnknown)
	}
	if got := unknown.AppendTags(nil); len(got) != 2 ||
		got[0] != backend.TagKey+registry.KVBackendUnknown ||
		got[1] != backend.FallbackTagKey+registry.KVFallbackUnknown {
		t.Errorf("unknown attribution tags = %v", got)
	}
	for _, bad := range []float64{0, -1} {
		if infermetrics.UsableSample(bad) {
			t.Errorf("usableMetricSample(%v) = true, want false", bad)
		}
	}

	srv, _, _ := billingTestServer(t)
	srv.NewMetrics().BackendLatency("m", backend.Attribution{
		Backend: registry.KVBackendPaged, Fallback: registry.KVFallbackNone,
	}, 12, 34)
	if got := backend.Resolve(srv.registry, "no-such-provider", "m"); got.Backend != registry.KVBackendUnknown ||
		got.Fallback != registry.KVFallbackUnknown {
		t.Errorf("attribution for an unknown provider = %+v", got)
	}

	if got := backend.ResolveProvider(nil, "m"); got.Backend != registry.KVBackendUnknown ||
		got.Fallback != registry.KVFallbackUnknown {
		t.Errorf("attribution for a nil provider = %+v", got)
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
	srv.observation.SetDatadog(dd)

	srv.NewMetrics().BackendLatency("m", backend.Attribution{
		Backend: registry.KVBackendPaged, Fallback: registry.KVFallbackNone,
	}, 0, 0)
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if hasMetric(packets, infermetrics.RequestTTFT) || hasMetric(packets, infermetrics.RequestDecodeTPS) {
		t.Errorf("zero-valued samples must not be emitted; packets=%v", packets)
	}
}
