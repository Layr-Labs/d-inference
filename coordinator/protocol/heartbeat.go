package protocol

// ProviderDrainingForUpdate is the well-known error reason a provider attaches
// to inference / load_model / prefetch_model rejections while it is draining
// ahead of an auto-update restart. The coordinator matches this exact string
// to treat such a load_model failure as transient (short retry backoff,
// provider is about to restart) rather than a genuine load failure that earns
// the full cooldown. Mirrored in
// provider-swift/Sources/ProviderCore/Protocol/Types.swift.
const ProviderDrainingForUpdate = "provider draining for update"

// HeartbeatStatusDraining is the HeartbeatMessage.Status a provider reports
// while it refuses new work ahead of a restart/update (the update drain, a
// shutdown drain). The coordinator skips a draining provider in routing and
// counts it as transient capacity (429 / queue material, never "no
// providers"). Additive: older coordinators ignore unknown status strings and
// older providers never send it. Mirrored in
// provider-swift/Sources/ProviderCore/Protocol/ (ProviderStatus).
const HeartbeatStatusDraining = "draining"

// InferenceErrorReasonDraining is the InferenceErrorMessage.ErrorReason a
// provider attaches (with failure_code "capacity", status 503) to an inference
// request it refuses BECAUSE it is draining. The coordinator fails the request
// over without consuming its transient-capacity retry allowance, derates no
// gray-box capacity state for the pair, and marks the provider draining so
// the next scan skips it even when the heartbeat status has not caught up.
// Mirrored in provider-swift/Sources/ProviderCore/Protocol/ (InferenceErrorReason).
const InferenceErrorReasonDraining = "draining"

// HeartbeatMessage is sent periodically by connected providers.
type HeartbeatMessage struct {
	Type            string           `json:"type"`
	Status          string           `json:"status"`
	ActiveModel     *string          `json:"active_model"`
	Stats           HeartbeatStats   `json:"stats"`
	WarmModels      []string         `json:"warm_models,omitempty"`      // models currently loaded in memory
	SystemMetrics   SystemMetrics    `json:"system_metrics"`             // live resource utilization
	BackendCapacity *BackendCapacity `json:"backend_capacity,omitempty"` // live backend capacity (nil for old providers)
	// Pointer preserves the distinction between an old provider that omitted
	// v2 capabilities and a v2 provider authoritatively clearing its live set.
	PrefixCacheProtocol     int                        `json:"prefix_cache_protocol,omitempty"`
	PrefixCacheV2Models     *[]PrefixCacheV2Capability `json:"prefix_cache_v2_models,omitempty"`
	PrefixCacheMemoryModels *[]PrefixCacheV2Capability `json:"prefix_cache_memory_models,omitempty"`
	// Optional pointers preserve old-provider omission versus an authoritative
	// empty snapshot/counter set from a current provider.
	PrefixCacheStatuses         *[]PrefixCacheModelStatus          `json:"prefix_cache_statuses,omitempty"`
	PrefixCacheDonationOutcomes *[]PrefixCacheDonationOutcomeCount `json:"prefix_cache_donation_outcomes,omitempty"`

	// APNs code-identity attestation (W5 Fix 2): a provider that only obtained
	// its APNs device token AFTER registration (headless/late-token Mac) — or
	// whose token rotated mid-connection — carries it here so the coordinator can
	// re-arm a code-identity challenge WITHOUT forcing a reconnect. Mirrors
	// RegisterMessage.APNsDeviceToken/APNsEnvironment. omitempty so providers that
	// never have a token (and the steady state) keep the wire shape unchanged; nil
	// when absent. SECURITY: the token here only lets the coordinator SEND a
	// challenge — it NEVER by itself grants CodeAttested. Attestation still
	// requires the full E_K(nonce) round-trip verified against the SE key bound at
	// registration (see api.handleCodeAttestationResponse).
	APNsDeviceToken string `json:"apns_device_token,omitempty"` // hex device token from registerForRemoteNotifications
	APNsEnvironment string `json:"apns_environment,omitempty"`  // "production" | "development" (selects the APNs host)

	// IdleUnloadMins is the operator's idle-memory policy (`[backend]
	// idle_timeout_mins` on the provider): minutes without requests before the
	// box unloads a model, or 0 when models stay resident ("always ready").
	// Pointer so 0 survives omitempty; nil = legacy provider that does not
	// report the policy. Informational only — it lets the owner's dashboard
	// tell "unloaded on purpose, wakes on demand" apart from "should be loaded
	// and isn't". Routing keys on live slot state, never on this field.
	IdleUnloadMins *int `json:"idle_unload_mins,omitempty"`
}

// SystemMetrics contains live resource utilization reported by a provider.
type SystemMetrics struct {
	MemoryPressure float64 `json:"memory_pressure"` // 0.0 to 1.0
	CPUUsage       float64 `json:"cpu_usage"`       // 0.0 to 1.0
	ThermalState   string  `json:"thermal_state"`   // nominal, fair, serious, critical
}

// HeartbeatStats contains counters reported in heartbeats.
type HeartbeatStats struct {
	RequestsServed               int64 `json:"requests_served"`
	TokensGenerated              int64 `json:"tokens_generated"`
	CancellationsReceived        int64 `json:"cancellations_received,omitempty"`
	CancellationsBeforeOutput    int64 `json:"cancellations_before_output,omitempty"`
	CancellationsPartialComplete int64 `json:"cancellations_partial_complete,omitempty"`
	GenerationErrorsAfterOutput  int64 `json:"generation_errors_after_output,omitempty"`
	ChunkEncryptionErrors        int64 `json:"chunk_encryption_errors,omitempty"`
	StreamClosedWithoutTerminal  int64 `json:"stream_closed_without_terminal,omitempty"`
	CancelDuringModelLoad        int64 `json:"cancel_during_model_load,omitempty"`
	UsageGaps                    int64 `json:"usage_gaps,omitempty"`

	// System-profiler cancel accounting (cumulative per session, delta-merged
	// like the counters above; absent on providers that predate them).
	CancelStagePreAcceptTotal    int64 `json:"cancel_stage_pre_accept_total,omitempty"`
	CancelStagePreEngineTotal    int64 `json:"cancel_stage_pre_engine_total,omitempty"`
	CancelStagePrefillTotal      int64 `json:"cancel_stage_prefill_total,omitempty"`
	CancelStageDecodeTotal       int64 `json:"cancel_stage_decode_total,omitempty"`
	CancelStagePostTerminalTotal int64 `json:"cancel_stage_post_terminal_total,omitempty"`
	TokensAfterCancelTotal       int64 `json:"tokens_after_cancel_total,omitempty"`
	CancelAbortNSSum             int64 `json:"cancel_abort_ns_sum,omitempty"`
}
