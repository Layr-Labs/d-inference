package contracts

import (
	"context"
	"encoding/json"
	"time"
)

// TelemetryEventRecord is the persistence-layer representation of a telemetry
// event. It mirrors protocol.TelemetryEvent but lives in this package so the
// store can stay free of protocol-layer dependencies.
type TelemetryEventRecord struct {
	ID         string          `json:"id"`
	Timestamp  time.Time       `json:"timestamp"`
	Source     string          `json:"source"`
	Severity   string          `json:"severity"`
	Kind       string          `json:"kind"`
	Version    string          `json:"version,omitempty"`
	MachineID  string          `json:"machine_id,omitempty"`
	AccountID  string          `json:"account_id,omitempty"`
	RequestID  string          `json:"request_id,omitempty"`
	SessionID  string          `json:"session_id,omitempty"`
	Message    string          `json:"message"`
	Fields     json.RawMessage `json:"fields,omitempty"`
	Stack      string          `json:"stack,omitempty"`
	ReceivedAt time.Time       `json:"received_at"`
}

// InferenceRouteRecord captures a single routing decision and the provider
// snapshot at the moment the scheduler made the choice. It contains no user
// prompt or response content.
type InferenceRouteRecord struct {
	RequestID               string  `json:"request_id"`
	Attempt                 int     `json:"attempt"`
	ProviderID              string  `json:"provider_id"`
	Model                   string  `json:"model"`
	PublicModel             string  `json:"public_model"`
	ConsumerKeyHash         string  `json:"consumer_key_hash"`
	KeyID                   string  `json:"key_id"`
	Outcome                 string  `json:"outcome"`
	CostMs                  float64 `json:"cost_ms"`
	StateMs                 float64 `json:"state_ms"`
	QueueMs                 float64 `json:"queue_ms"`
	PendingMs               float64 `json:"pending_ms"`
	BacklogMs               float64 `json:"backlog_ms"`
	ThisReqMs               float64 `json:"this_req_ms"`
	HealthMs                float64 `json:"health_ms"`
	TTFTMs                  float64 `json:"ttft_ms"`
	BestTTFTMs              float64 `json:"best_ttft_ms"`
	EffectiveQueue          int     `json:"effective_queue"`
	CandidateCount          int     `json:"candidate_count"`
	CapacityRejections      int     `json:"capacity_rejections"`
	ModelTooLargeRejections int     `json:"model_too_large_rejections"`
	VisionRejections        int     `json:"vision_rejections"`
	TTFTRejections          int     `json:"ttft_rejections"`
	EffectiveTPS            float64 `json:"effective_tps"`
	StaticTPS               float64 `json:"static_tps"`

	ProviderStatus        string  `json:"provider_status"`
	ProviderTrustLevel    string  `json:"provider_trust_level"`
	ProviderVersion       string  `json:"provider_version"`
	HardwareChip          string  `json:"hardware_chip"`
	HardwareChipFamily    string  `json:"hardware_chip_family"`
	HardwareTier          string  `json:"hardware_tier"`
	MemoryGB              int     `json:"memory_gb"`
	GPUCores              int     `json:"gpu_cores"`
	CPUCores              int     `json:"cpu_cores"`
	SystemMemoryPressure  float64 `json:"system_memory_pressure"`
	SystemCPUUsage        float64 `json:"system_cpu_usage"`
	SystemThermalState    string  `json:"system_thermal_state"`
	GPUMemoryActiveGB     float64 `json:"gpu_memory_active_gb"`
	GPUMemoryPeakGB       float64 `json:"gpu_memory_peak_gb"`
	GPUMemoryCacheGB      float64 `json:"gpu_memory_cache_gb"`
	SlotState             string  `json:"slot_state"`
	BackendRunning        int     `json:"backend_running"`
	BackendWaiting        int     `json:"backend_waiting"`
	ActiveTokenBudgetUsed int64   `json:"active_token_budget_used"`
	ActiveTokenBudgetMax  int64   `json:"active_token_budget_max"`
	QueuedTokenBudget     int64   `json:"queued_token_budget"`

	EstimatedPromptTokens int  `json:"estimated_prompt_tokens"`
	RequestedMaxTokens    int  `json:"requested_max_tokens"`
	RequiresVision        bool `json:"requires_vision"`
	HasTools              bool `json:"has_tools"`
	SelfRouteOnly         bool `json:"self_route_only"`
	PreferOwner           bool `json:"prefer_owner"`

	// Geo (coarse region of provider/consumer; no raw IPs). Optional.
	ProviderRegion string `json:"provider_region,omitempty"`
	ConsumerRegion string `json:"consumer_region,omitempty"`

	// Final outcome data, merged from InferenceRouteOutcome updates.
	FinalStatus            string  `json:"final_status"`
	ErrorCode              int     `json:"error_code"`
	ErrorClass             string  `json:"error_class"`
	ErrorReason            string  `json:"error_reason,omitempty"`
	PromptTokens           int     `json:"prompt_tokens"`
	CompletionTokens       int     `json:"completion_tokens"`
	ReasoningTokens        int     `json:"reasoning_tokens"`
	CostMicroUSD           int64   `json:"cost_micro_usd"`
	ActualTTFTMs           float64 `json:"actual_ttft_ms"`
	DispatchToFirstChunkMs float64 `json:"dispatch_to_first_chunk_ms"`
	TotalDurationMs        float64 `json:"total_duration_ms"`
	ParseMs                float64 `json:"parse_ms"`
	ReserveMs              float64 `json:"reserve_ms"`
	RouteMs                float64 `json:"route_ms"`
	EncryptMs              float64 `json:"encrypt_ms"`
	QueueWaitMs            float64 `json:"queue_wait_ms"`
	DispatchMs             float64 `json:"dispatch_ms"`
	ActualDecodeTPS        float64 `json:"actual_decode_tps"`
	AdmittedButFailed      bool    `json:"admitted_but_failed"`
	UsedBackup             bool    `json:"used_backup"`
	BackupWon              bool    `json:"backup_won"`

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

// InferenceRouteOutcome carries the final result of a routed request attempt.
type InferenceRouteOutcome struct {
	FinalStatus            string  `json:"final_status"`
	ErrorCode              int     `json:"error_code"`
	ErrorClass             string  `json:"error_class"`
	ErrorReason            string  `json:"error_reason,omitempty"`
	PromptTokens           int     `json:"prompt_tokens"`
	CompletionTokens       int     `json:"completion_tokens"`
	ReasoningTokens        int     `json:"reasoning_tokens"`
	CostMicroUSD           int64   `json:"cost_micro_usd"`
	ActualTTFTMs           float64 `json:"actual_ttft_ms"`
	DispatchToFirstChunkMs float64 `json:"dispatch_to_first_chunk_ms"`
	TotalDurationMs        float64 `json:"total_duration_ms"`

	// Coordinator-side latency decomposition (ms). Zero = not measured.
	ParseMs     float64 `json:"parse_ms"`
	ReserveMs   float64 `json:"reserve_ms"`
	RouteMs     float64 `json:"route_ms"`
	EncryptMs   float64 `json:"encrypt_ms"`
	QueueWaitMs float64 `json:"queue_wait_ms"` // measured enqueue -> dispatch
	DispatchMs  float64 `json:"dispatch_ms"`

	// Measured decode throughput for the completed request (tokens/s).
	ActualDecodeTPS float64 `json:"actual_decode_tps"`

	// AdmittedButFailed is true when the coordinator admitted the request but the
	// provider failed it (OOM / load failure) — the admission-gate mismatch.
	AdmittedButFailed bool `json:"admitted_but_failed"`
	// Speculative/backup-race dispatch outcome.
	UsedBackup bool `json:"used_backup"`
	BackupWon  bool `json:"backup_won"`

	// CompletionTokensSet forces the completion_tokens column to be written from
	// CompletionTokens even when it is 0. Without it, a terminal cancel/error/
	// timeout row (which delivers 0 tokens) leaves completion_tokens NULL, so the
	// incident-majority 0-token cancels are invisible in telemetry. Success rows
	// already write a real (usually non-zero) count, so this only needs to be set
	// on the terminal cancel/error/timeout constructors (and success, harmlessly).
	CompletionTokensSet bool `json:"completion_tokens_set,omitempty"`

	// InvalidTTFT is a transient (never-persisted) signal that the raw
	// time-to-first-token computed for this outcome was negative and was clamped
	// to 0. The single store-submit funnel emits routing.invalid_ttft when it is
	// set, so any regression of the retried-request shared-Timing bug
	// (FirstContentAt of an early attempt minus a later attempt's DispatchedAt)
	// is loud rather than silent. json:"-" keeps it out of every API payload and
	// neither store impl persists it.
	InvalidTTFT bool `json:"-"`

	// QueueExit is a transient (never-persisted) marker on the terminal outcome
	// of a request that left the coordinator queue without a provider attempt
	// being dispatched (client gone, queue_deadline, queue_timeout,
	// ttft_too_slow, tool-constraint unavailable). The route-outcome funnel
	// counts such an exit on inference.queue_outcome instead of
	// inference.attempt_outcome, so the per-model attempt denominator only
	// counts attempts a provider actually received.
	QueueExit bool `json:"-"`
}

// InferenceRouteOutcomeUpdate is one outcome update addressed to a route row,
// used by the batched UpdateInferenceRouteOutcomes path. It carries exactly the
// arguments of UpdateInferenceRouteOutcome; Outcome nil is skipped.
type InferenceRouteOutcomeUpdate struct {
	RequestID string
	Attempt   int
	Outcome   *InferenceRouteOutcome
}

// RejectionRecord captures a single rejected inbound inference request (4xx/5xx)
// at any stage of the pipeline, with the request's parameters and a
// counterfactual servability snapshot ("could the fleet have served it?"). It
// contains no prompt or response content.
type RejectionRecord struct {
	RequestID       string `json:"request_id,omitempty"`
	Endpoint        string `json:"endpoint"`
	Stage           string `json:"stage"`       // auth, validation, model_resolution, balance, rate_limit, preflight_capacity, routing_ttft
	ReasonCode      string `json:"reason_code"` // e.g. model_not_found, machine_busy, insufficient_funds
	HTTPStatus      int    `json:"http_status"`
	ConsumerKeyHash string `json:"consumer_key_hash,omitempty"`
	KeyID           string `json:"key_id,omitempty"`
	ClientClass     string `json:"client_class,omitempty"` // e.g. openrouter, direct

	// Request shape / params (non-private — no content).
	RequestedModel        string          `json:"requested_model"` // raw, as the client sent it
	ResolvedModel         string          `json:"resolved_model,omitempty"`
	Stream                bool            `json:"stream"`
	N                     int             `json:"n,omitempty"`
	EstimatedPromptTokens int             `json:"estimated_prompt_tokens"`
	RequestedMaxTokens    int             `json:"requested_max_tokens"`
	RequiresVision        bool            `json:"requires_vision"`
	HasImage              bool            `json:"has_image"`
	HasAudio              bool            `json:"has_audio"`
	HasTools              bool            `json:"has_tools"`
	ToolCount             int             `json:"tool_count,omitempty"`
	ResponseFormat        string          `json:"response_format,omitempty"`
	SelfRouteOnly         bool            `json:"self_route_only"`
	PreferOwner           bool            `json:"prefer_owner"`
	Params                json.RawMessage `json:"params,omitempty"` // non-content knobs (temperature, top_p, …)
	RequestBodyBytes      int             `json:"request_body_bytes,omitempty"`
	RetryAfterMs          int             `json:"retry_after_ms,omitempty"`

	// Counterfactual servability: nil means not evaluated; only a non-nil
	// value answers whether the fleet could have produced output.
	CouldHaveServed         *bool   `json:"could_have_served"`
	CandidateCount          int     `json:"candidate_count"`
	CapacityRejections      int     `json:"capacity_rejections"`
	ModelTooLargeRejections int     `json:"model_too_large_rejections"`
	VisionRejections        int     `json:"vision_rejections"`
	WarmProviderExisted     bool    `json:"warm_provider_existed"`
	BestTTFTMs              float64 `json:"best_ttft_ms,omitempty"`
	ShortfallMicroUSD       int64   `json:"shortfall_micro_usd,omitempty"` // for 402
	LimitKind               string  `json:"limit_kind,omitempty"`          // for 429 rate-limit
	OverBy                  int64   `json:"over_by,omitempty"`

	CreatedAt time.Time `json:"created_at"`
}

// TelemetryStore persists routing-decision snapshots and rejection records
// (privacy-safe, no prompt/response content). Forwarded to Datadog elsewhere.
type TelemetryStore interface {
	// RecordInferenceRoute writes or refreshes the routing decision snapshot for a
	// request attempt. Best-effort; failures must not block inference.
	RecordInferenceRoute(record *InferenceRouteRecord) error

	// RecordInferenceRoutes persists a batch of routing decision snapshots with
	// exactly the per-row semantics of RecordInferenceRoute (upsert on
	// request_id/attempt, zero CreatedAt/UpdatedAt defaulted to now), issued as
	// one multi-row statement per chunk instead of one round trip per record.
	// Records are applied in slice order; a duplicate (request_id, attempt) key
	// within the slice starts a new statement so the later record refreshes the
	// earlier one exactly as sequential calls would. Nil records are skipped.
	RecordInferenceRoutes(records []*InferenceRouteRecord) error

	// UpdateInferenceRouteOutcome updates the attempt with final outcome data
	// (tokens, timing, error). Best-effort; failures must not block inference.
	UpdateInferenceRouteOutcome(requestID string, attempt int, outcome *InferenceRouteOutcome) error

	// UpdateInferenceRouteOutcomes applies a batch of outcome updates in slice
	// order with exactly the per-row semantics of UpdateInferenceRouteOutcome,
	// pipelined as one round trip. Updates with a nil Outcome are skipped.
	UpdateInferenceRouteOutcomes(updates []InferenceRouteOutcomeUpdate) error

	// InferenceRouteRecordsSince returns routing records created at or after the
	// given time, newest-first, capped at the shared telemetry read limit. Zero since includes all creation times, subject to the same cap.
	InferenceRouteRecordsSince(since time.Time) []InferenceRouteRecord

	// RecordRejection writes a rejected-request record (4xx/5xx) with its
	// counterfactual servability snapshot. Best-effort; failures must not block
	// the request path.
	RecordRejection(record *RejectionRecord) error

	// RejectionRecordsSince returns rejection records created at or after the
	// given time, newest-first, capped at the shared telemetry read limit. Zero since includes all creation times, subject to the same cap.
	RejectionRecordsSince(since time.Time) []RejectionRecord

	// RecordRequestProfiles writes one request_profiles row per record in a
	// single multi-row INSERT ... ON CONFLICT (request_id, attempt) DO NOTHING
	// (write-once; a duplicate attempt is silently skipped). nil/empty input is
	// a no-op. Best-effort; failures must not block inference.
	RecordRequestProfiles(records []*RequestProfileRecord) error

	// RequestProfilesSince returns request profiles created at or after the
	// given time, newest-first, capped at maxTelemetryReadRows. Zero since
	// returns the newest rows across all time.
	RequestProfilesSince(since time.Time) []RequestProfileRecord

	// RequestProfilesSinceFiltered is RequestProfilesSince with the admin
	// browse/export predicates applied BEFORE the read cap, so a matching row
	// older than the newest maxTelemetryReadRows rows is still returned.
	RequestProfilesSinceFiltered(since time.Time, filter RequestProfileFilter) []RequestProfileRecord

	// RecordFleetSnapshots bulk-writes one sampler tick (one row per provider
	// slot plus the coordinator row). nil/empty input is a no-op. Best-effort.
	RecordFleetSnapshots(rows []FleetSnapshotRow) error

	// FleetSnapshotsSince returns fleet snapshot rows sampled at or after the
	// given time, newest-first, capped at maxTelemetryReadRows.
	FleetSnapshotsSince(since time.Time) []FleetSnapshotRow

	// PruneTelemetry deletes request_profiles rows created before
	// profilesBefore and fleet_snapshots rows sampled before snapshotsBefore in
	// primary-key batches of at most batch rows, each in its own short
	// transaction, stopping at the first error or when ctx is done. It returns
	// the number of rows deleted before stopping.
	PruneTelemetry(ctx context.Context, profilesBefore, snapshotsBefore time.Time, batch int) (deleted int, err error)
}
