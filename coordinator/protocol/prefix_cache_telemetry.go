package protocol

// PrefixCacheTelemetry is an optional low-rate observation, never an admission
// input. Generation identifies a loaded cache only within this provider process;
// SampleSeq advances on a new observation, SampleAgeMS advances on heartbeats.
type PrefixCacheTelemetry struct {
	Kind               string                  `json:"kind"`
	Generation         uint64                  `json:"generation"`
	SampleSeq          uint64                  `json:"sample_seq"`
	SampleAgeMS        uint64                  `json:"sample_age_ms"`
	Entries            uint64                  `json:"entries"`
	DiskBytes          uint64                  `json:"disk_bytes"`
	StagingBytes       uint64                  `json:"staging_bytes"`
	StagesTotal        uint64                  `json:"stages_total"`
	FilesWrittenTotal  uint64                  `json:"files_written_total"`
	WrittenBytesTotal  uint64                  `json:"written_bytes_total"`
	DonationDropsTotal uint64                  `json:"donation_drops_total"`
	CorruptDropsTotal  uint64                  `json:"corrupt_drops_total"`
	EvictionsTotal     uint64                  `json:"evictions_total"`
	TTLExpiredTotal    *uint64                 `json:"ttl_expired_total,omitempty"`
	IO                 *PrefixCacheIOTelemetry `json:"io,omitempty"`
}

type PrefixCacheIOTelemetry struct {
	StagingPeakBytes       uint64 `json:"staging_peak_bytes"`
	FilesReadTotal         uint64 `json:"files_read_total"`
	ReadBytesTotal         uint64 `json:"read_bytes_total"`
	StageReadBytesTotal    uint64 `json:"stage_read_bytes_total"`
	DonationReadBytesTotal uint64 `json:"donation_read_bytes_total"`
	StageUSTotal           uint64 `json:"stage_us_total"`
	WriteUSTotal           uint64 `json:"write_us_total"`
}

type PrefixCacheMaintenanceTelemetry struct {
	TTLExpiredTotal    uint64 `json:"ttl_expired_total"`
	BudgetEvictedTotal uint64 `json:"budget_evicted_total"`
	TempRemovedTotal   uint64 `json:"temp_removed_total"`
}

func (s *PrefixCacheTelemetry) Clone() *PrefixCacheTelemetry {
	if s == nil {
		return nil
	}
	copy := *s
	if s.TTLExpiredTotal != nil {
		value := *s.TTLExpiredTotal
		copy.TTLExpiredTotal = &value
	}
	if s.IO != nil {
		value := *s.IO
		copy.IO = &value
	}
	return &copy
}
