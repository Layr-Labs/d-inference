package sidecar

type ReadinessStatus struct {
	Status string `json:"status"`
	Ready  bool   `json:"ready"`
}

type PreloadResult struct {
	PromptContractID string `json:"prompt_contract_id"`
	Status           string `json:"status"`
}

type PreloadReport struct {
	Status    string          `json:"status"`
	Ready     bool            `json:"ready"`
	Requested int             `json:"requested"`
	Warm      int             `json:"warm"`
	Cold      int             `json:"cold"`
	Failed    int             `json:"failed"`
	Results   []PreloadResult `json:"results"`
	Metrics   SidecarMetrics  `json:"metrics"`
}

type SidecarStatus struct {
	Status                   string         `json:"status"`
	Ready                    bool           `json:"ready"`
	LoadedContracts          int            `json:"loaded_contracts"`
	LoadingContracts         int            `json:"loading_contracts"`
	MaxLoadedContracts       int            `json:"max_loaded_contracts"`
	PlanningPermitsAvailable int            `json:"planning_permits_available"`
	MaxPlanningConcurrency   int            `json:"max_planning_concurrency"`
	Metrics                  SidecarMetrics `json:"metrics"`
}

type SidecarMetrics struct {
	Plans         SidecarPlanMetrics     `json:"plans"`
	ContractLoads SidecarContractMetrics `json:"contract_loads"`
	Preloads      SidecarPreloadMetrics  `json:"preloads"`
}

type SidecarPlanMetrics struct {
	Started    uint64                 `json:"started"`
	Succeeded  uint64                 `json:"succeeded"`
	ColdOnly   uint64                 `json:"cold_only"`
	Failed     uint64                 `json:"failed"`
	AtCapacity uint64                 `json:"at_capacity"`
	NotReady   uint64                 `json:"not_ready"`
	TimedOut   uint64                 `json:"timed_out"`
	LatencyUS  SidecarLatencySnapshot `json:"latency_us"`
}

type SidecarContractMetrics struct {
	Cold          uint64                 `json:"cold"`
	Warm          uint64                 `json:"warm"`
	Waited        uint64                 `json:"waited"`
	Failed        uint64                 `json:"failed"`
	ColdLatencyUS SidecarLatencySnapshot `json:"cold_latency_us"`
}

type SidecarPreloadMetrics struct {
	Runs      uint64 `json:"runs"`
	Failed    uint64 `json:"failed"`
	Contracts uint64 `json:"contracts"`
}

type SidecarLatencySnapshot struct {
	Count   uint64                 `json:"count"`
	TotalUS uint64                 `json:"total_us"`
	MaxUS   uint64                 `json:"max_us"`
	Buckets []SidecarLatencyBucket `json:"buckets"`
}

type SidecarLatencyBucket struct {
	LessThanOrEqualUS *uint64 `json:"less_than_or_equal_us,omitempty"`
	CumulativeCount   uint64  `json:"cumulative_count"`
}
