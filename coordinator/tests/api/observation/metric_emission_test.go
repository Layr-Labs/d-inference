package observation_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/observation"
)

func TestAttestationMetrics_AllOutcomes(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv := &production.Owner{}
	srv.SetDatadog(ddClient)
	for _, outcome := range []string{"passed", "failed", "status_sig_missing"} {
		srv.Incr("attestation.challenges", []string{"outcome:" + outcome})
	}
	srv.Incr("attestation.challenges_sent", nil)
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	for _, outcome := range []string{"passed", "failed", "status_sig_missing"} {
		if !hasMetric(packets, "outcome:"+outcome) {
			t.Errorf("missing attestation.challenges{outcome:%s}; got packets: %v", outcome, packets)
		}
	}
	if !hasMetric(packets, "attestation.challenges_sent") {
		t.Errorf("missing attestation.challenges_sent; got packets: %v", packets)
	}
}

func TestInferenceMetrics_CompletionCounters(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv := &production.Owner{}
	srv.SetDatadog(ddClient)
	model := "test-completion-model"
	srv.Incr("inference.completions", []string{"model:" + model})
	srv.Histogram("inference.completion_tokens", 42, []string{"model:" + model})
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	if !hasMetric(packets, "inference.completions") {
		t.Errorf("missing inference.completions; got packets: %v", packets)
	}
	if !hasMetric(packets, "inference.completion_tokens") {
		t.Errorf("missing inference.completion_tokens; got packets: %v", packets)
	}
	if !hasMetric(packets, "model:"+model) {
		t.Errorf("missing model tag; got packets: %v", packets)
	}
}

func TestDDMetrics_NilClientNoOps(t *testing.T) {
	srv := &production.Owner{}
	// Must not panic when dd is nil.
	srv.Incr("test.counter", []string{"a:b"})
	srv.Histogram("test.histogram", 1.0, []string{"a:b"})
	srv.Gauge("test.gauge", 1.0, []string{"a:b"})
}
