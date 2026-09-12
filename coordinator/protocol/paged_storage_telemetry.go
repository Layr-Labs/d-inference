package protocol

// PagedStorageTelemetry is a queue-captured observation, never an admission
// input. Byte gauges overlap: reserved/live pages are not additional owners on
// top of committed bytes. Missing instrumentation is distinct from zero.
type PagedStorageTelemetry struct {
	Kind        string `json:"kind"`
	Generation  uint64 `json:"generation"`
	SampleSeq   uint64 `json:"sample_seq"`
	SampleAgeMS uint64 `json:"sample_age_ms"`

	GrantBytes        uint64 `json:"grant_bytes"`
	CommittedBytes    uint64 `json:"committed_bytes"`
	ReservedPageBytes uint64 `json:"reserved_page_bytes"`
	LivePageBytes     uint64 `json:"live_page_bytes"`
	PoisonBytes       uint64 `json:"poison_bytes"`
	SlackBytes        uint64 `json:"slack_bytes"`
	OverGrantBytes    uint64 `json:"over_grant_bytes"`
	SegmentCount      uint64 `json:"segment_count"`
	AddressPages      uint64 `json:"address_pages"`

	// Optional on older producers; padding is not reusable KV slack.
	AllocatorPaddingBytes        *uint64 `json:"allocator_padding_bytes,omitempty"`
	LastAllocationAllowanceBytes *uint64 `json:"last_allocation_allowance_bytes,omitempty"`
	NominalKVBytes               *uint64 `json:"nominal_kv_bytes,omitempty"`
	PhysicalFloorOverheadBytes   *uint64 `json:"physical_floor_overhead_bytes,omitempty"`
	AllocationFailuresTotal      *uint64 `json:"allocation_failures_total,omitempty"`
	AdmissionRefusalsTotal       *uint64 `json:"admission_refusals_total,omitempty"`
	GrantRefusalsTotal           *uint64 `json:"grant_refusals_total,omitempty"`
	GrantEpochRetriesTotal       *uint64 `json:"grant_epoch_retries_total,omitempty"`
}

func (s *PagedStorageTelemetry) Clone() *PagedStorageTelemetry {
	if s == nil {
		return nil
	}
	copy := *s
	for _, field := range []**uint64{&copy.AllocatorPaddingBytes, &copy.LastAllocationAllowanceBytes, &copy.NominalKVBytes, &copy.PhysicalFloorOverheadBytes,
		&copy.AllocationFailuresTotal, &copy.AdmissionRefusalsTotal, &copy.GrantRefusalsTotal, &copy.GrantEpochRetriesTotal} {
		if *field != nil {
			value := **field
			*field = &value
		}
	}
	return &copy
}
