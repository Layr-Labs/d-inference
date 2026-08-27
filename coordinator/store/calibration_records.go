package store

import "time"

// Candidate rejection reasons persisted on inference_route_candidates.
// These are closed enums — never raw provider text.
const (
	CandidateRejectNone             = ""
	CandidateRejectCapacity         = "capacity"
	CandidateRejectModelTooLarge    = "model_too_large"
	CandidateRejectVision           = "vision"
	CandidateRejectTTFT             = "ttft"
	CandidateRejectCatalog          = "catalog"
	CandidateRejectLoadCooldown     = "load_cooldown"
	CandidateRejectErrorCooldown    = "error_cooldown"
	CandidateRejectCapacityCooldown = "capacity_cooldown"
	CandidateRejectBreaker          = "breaker"
	CandidateRejectHealthEjection   = "health_ejection"
	CandidateRejectLiveness         = "liveness"
	CandidateRejectTrait            = "trait"
	CandidateRejectPreferOwner      = "prefer_owner"
	CandidateRejectAvoidVersion     = "avoid_version"
	CandidateRejectMinDecodeTPS     = "min_decode_tps"
	CandidateRejectSlotCrashed      = "slot_crashed"
	CandidateRejectSlotReloading    = "slot_reloading"
	CandidateRejectThermalCritical  = "thermal_critical"
)

// InferenceRouteCandidateRecord is one provider the scheduler considered for a
// request attempt. Eligible rows carry the full cost breakdown so we can
// measure ranking regret (winner vs runner-up). Ineligible rows record why a
// machine that passed structural gates still lost before scoring or after a
// TTFT ceiling. No prompt or response content.
type InferenceRouteCandidateRecord struct {
	RequestID       string `json:"request_id"`
	Attempt         int    `json:"attempt"`
	ProviderID      string `json:"provider_id"`
	Rank            int    `json:"rank"` // 0 = cheapest eligible; -1 = ineligible
	Selected        bool   `json:"selected"`
	Eligible        bool   `json:"eligible"`
	RejectionReason string `json:"rejection_reason,omitempty"`

	CostMs              float64 `json:"cost_ms"`
	StateMs             float64 `json:"state_ms"`
	QueueMs             float64 `json:"queue_ms"`
	PendingMs           float64 `json:"pending_ms"`
	BacklogMs           float64 `json:"backlog_ms"`
	ThisReqMs           float64 `json:"this_req_ms"`
	HealthMs            float64 `json:"health_ms"`
	CapacityRateMs      float64 `json:"capacity_rate_ms"`
	TTFTMs              float64 `json:"ttft_ms"`
	EffectiveQueue      int     `json:"effective_queue"`
	EffectiveTPS        float64 `json:"effective_tps"`
	StaticTPS           float64 `json:"static_tps"`
	EffectivePrefillTPS float64 `json:"effective_prefill_tps"`
	StaticPrefillTPS    float64 `json:"static_prefill_tps"`
	BatchSize           int     `json:"batch_size"`
	ChipFamily          string  `json:"chip_family,omitempty"`
	HardwareTier        string  `json:"hardware_tier,omitempty"`
	MemoryGB            int     `json:"memory_gb"`
	SlotState           string  `json:"slot_state,omitempty"`
	MemoryPressure      float64 `json:"memory_pressure"`
	ThermalState        string  `json:"thermal_state,omitempty"`
	GPUMemoryActiveGB   float64 `json:"gpu_memory_active_gb"`
	FreeForLoadGB       float64 `json:"free_for_load_gb"`
	WedgeSuspected      bool    `json:"wedge_suspected"`
	AffinityApplied     bool    `json:"affinity_applied"`
	AffinityDiscountMs  float64 `json:"affinity_discount_ms"`
	CapacityRejectRate  float64 `json:"capacity_reject_rate"`

	CreatedAt time.Time `json:"created_at"`
}

// ProviderCapacitySample is a request-independent heartbeat snapshot used to
// fit TPS-vs-batch and health-vs-throughput curves. Sampled, not every
// heartbeat. No prompt or response content.
type ProviderCapacitySample struct {
	ProviderID         string    `json:"provider_id"`
	ProviderVersion    string    `json:"provider_version,omitempty"`
	ProviderStatus     string    `json:"provider_status,omitempty"`
	ProviderTrustLevel string    `json:"provider_trust_level,omitempty"`
	HardwareChipFamily string    `json:"hardware_chip_family,omitempty"`
	HardwareTier       string    `json:"hardware_tier,omitempty"`
	MemoryGB           int       `json:"memory_gb"`
	CurrentModel       string    `json:"current_model,omitempty"`
	WarmModelCount     int       `json:"warm_model_count"`
	SlotCount          int       `json:"slot_count"`
	BackendRunning     int       `json:"backend_running"`
	BackendWaiting     int       `json:"backend_waiting"`
	ObservedDecodeTPS  float64   `json:"observed_decode_tps"`
	ActiveTokenUsed    int64     `json:"active_token_budget_used"`
	ActiveTokenMax     int64     `json:"active_token_budget_max"`
	QueuedTokenBudget  int64     `json:"queued_token_budget"`
	MemoryPressure     float64   `json:"memory_pressure"`
	CPUUsage           float64   `json:"cpu_usage"`
	ThermalState       string    `json:"thermal_state,omitempty"`
	GPUMemoryActiveGB  float64   `json:"gpu_memory_active_gb"`
	GPUMemoryPeakGB    float64   `json:"gpu_memory_peak_gb"`
	GPUMemoryCacheGB   float64   `json:"gpu_memory_cache_gb"`
	FreeForLoadGB      float64   `json:"free_for_load_gb"`
	WedgeSuspected     bool      `json:"wedge_suspected"`
	CreatedAt          time.Time `json:"created_at"`
}
