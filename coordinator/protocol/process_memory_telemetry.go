package protocol

// ProcessMemoryTelemetry is one coherent process admission observation. Charged
// C includes materialized M; U+(C-M) is the projection, never U+C. It is diagnostic
// only. Omitted instrumentation and OS availability remain unknown.
type ProcessMemoryTelemetry struct {
	Generation             uint64  `json:"generation"`
	SampleSeq              uint64  `json:"sample_seq"`
	SampleAgeMS            uint64  `json:"sample_age_ms"`
	PolicyEpoch            uint64  `json:"policy_epoch"`
	CapBytes               uint64  `json:"cap_bytes"`
	ActivationReserveBytes uint64  `json:"activation_reserve_bytes"`
	ActiveBytes            uint64  `json:"active_bytes"`
	CacheBytes             uint64  `json:"cache_bytes"`
	ChargedBytes           uint64  `json:"charged_bytes"`
	MaterializedBytes      uint64  `json:"materialized_bytes"`
	UnmaterializedBytes    uint64  `json:"unmaterialized_bytes"`
	RemainingBytes         uint64  `json:"remaining_bytes"`
	CommitmentDebtBytes    uint64  `json:"commitment_debt_bytes"`
	OwnerCount             uint64  `json:"owner_count"`
	ClosingOwnerCount      uint64  `json:"closing_owner_count"`
	SystemAvailableBytes   *uint64 `json:"system_available_bytes,omitempty"`
}

func (s *ProcessMemoryTelemetry) Clone() *ProcessMemoryTelemetry {
	if s == nil {
		return nil
	}
	result := *s
	result.SystemAvailableBytes = clonePtr(s.SystemAvailableBytes)
	return &result
}
