package protocol

// PerformanceRateObservation identifies an engine observation independently of
// heartbeat cadence. Age is monotonic elapsed milliseconds at provider snapshot.
type PerformanceRateObservation struct {
	TokensPerSecond float64 `json:"tokens_per_second"`
	SampleCount     int64   `json:"sample_count"`
	SampleAgeMS     int64   `json:"sample_age_ms"`
}

type PerformanceWorkloadBucket struct {
	// native_media_prefill describes completed native target-decoder work,
	// excluding encoder preparation. It is diagnostic, never a text rate.
	Phase              string                     `json:"phase"`
	PromptTokenBucket  int                        `json:"prompt_token_bucket"`
	ContextTokenBucket int                        `json:"context_token_bucket"`
	CacheState         string                     `json:"cache_state"`
	Contention         string                     `json:"contention"`
	OtherModelActivity bool                       `json:"other_model_activity"`
	Observation        PerformanceRateObservation `json:"observation"`
}

// PerformanceMeasurements is optional for legacy providers. Epoch changes with
// each engine bridge lifetime; workload buckets carry numeric shapes only.
type PerformanceMeasurements struct {
	Epoch            string                      `json:"epoch"`
	IsolatedPrefill  *PerformanceRateObservation `json:"isolated_prefill,omitempty"`
	ContendedPrefill *PerformanceRateObservation `json:"contended_prefill,omitempty"`
	Decode           *PerformanceRateObservation `json:"decode,omitempty"`
	DeliveredDecode  *PerformanceRateObservation `json:"delivered_decode,omitempty"`
	EndToEnd         *PerformanceRateObservation `json:"end_to_end,omitempty"`
	WorkloadBuckets  []PerformanceWorkloadBucket `json:"workload_buckets"`
}

func (p *PerformanceMeasurements) Clone() *PerformanceMeasurements {
	if p == nil {
		return nil
	}
	out := *p
	out.IsolatedPrefill = clonePtr(p.IsolatedPrefill)
	out.ContendedPrefill = clonePtr(p.ContendedPrefill)
	out.Decode = clonePtr(p.Decode)
	out.DeliveredDecode = clonePtr(p.DeliveredDecode)
	out.EndToEnd = clonePtr(p.EndToEnd)
	out.WorkloadBuckets = append([]PerformanceWorkloadBucket(nil), p.WorkloadBuckets...)
	return &out
}
