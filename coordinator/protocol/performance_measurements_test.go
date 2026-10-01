package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPerformanceMeasurementsOptionalWire(t *testing.T) {
	var old BackendSlotCapacity
	if err := json.Unmarshal([]byte(`{"model":"m","telemetry":{"prefill_tokens_total":42}}`), &old); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(old)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(encoded), "performance_measurements") {
		t.Fatal("legacy telemetry invented metadata")
	}
	payload := `{"model":"m","telemetry":{"prefill_tokens_total":200,"prefill_requests_total":1,"generated_tokens_total":10,"generation_requests_total":1},"performance_measurements":{"epoch":"engine-a","isolated_prefill":{"tokens_per_second":2000,"sample_count":1,"sample_age_ms":20},"decode":{"tokens_per_second":100,"sample_count":2,"sample_age_ms":10},"workload_buckets":[]}}`
	var telemetry BackendSlotCapacity
	if err := json.Unmarshal([]byte(payload), &telemetry); err != nil {
		t.Fatal(err)
	}
	if telemetry.PerformanceMeasurements.Epoch != "engine-a" || *telemetry.Telemetry.GeneratedTokensTotal != 10 || *telemetry.Telemetry.PrefillRequestsTotal != 1 {
		t.Fatalf("wire lost measurements: %+v", telemetry)
	}
	encoded, err = json.Marshal(telemetry)
	if err != nil {
		t.Fatal(err)
	}
	var roundTrip map[string]any
	if err = json.Unmarshal(encoded, &roundTrip); err != nil {
		t.Fatal(err)
	}
	if _, ok := roundTrip["performance_measurements"]; !ok {
		t.Fatal("metadata omitted")
	}
}

func TestMimoCalibrationConcurrencyWireIsOptional(t *testing.T) {
	legacy, err := json.Marshal(PerformanceWorkloadBucket{})
	if err != nil || strings.Contains(string(legacy), "concurrent_requests") {
		t.Fatalf("legacy bucket invented concurrency: %s (%v)", legacy, err)
	}
	var bucket PerformanceWorkloadBucket
	if err := json.Unmarshal([]byte(`{"phase":"decode","concurrent_requests":4}`), &bucket); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(bucket)
	if err != nil || bucket.ConcurrentRequests != 4 || !strings.Contains(string(encoded), `"concurrent_requests":4`) {
		t.Fatalf("measured concurrency lost in round trip: %s (%v)", encoded, err)
	}
}
