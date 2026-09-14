package protocol

// LoadModelStatus is the lifecycle state reported by a provider in response
// to a LoadModelMessage.
const (
	LoadModelStatusStarted   = "started"
	LoadModelStatusSucceeded = "succeeded"
	LoadModelStatusFailed    = "failed"
)

// PrefetchModelStatus is the lifecycle state reported by a provider in
// response to a PrefetchModelMessage. Unlike a load, a prefetch only
// downloads + verifies the model on disk; it does NOT load weights into
// GPU memory, so "verified" (not "succeeded") is the terminal success
// state: the build is on disk, hash-checked, and ready to be advertised.
const (
	PrefetchModelStatusStarted     = "started"
	PrefetchModelStatusDownloading = "downloading"
	PrefetchModelStatusVerified    = "verified"
	PrefetchModelStatusFailed      = "failed"
)

// ModelInfo describes a model available on a provider.
type ModelInfo struct {
	ID           string `json:"id"`
	SizeBytes    int64  `json:"size_bytes"`
	ModelType    string `json:"model_type"`
	Quantization string `json:"quantization"`
	WeightHash   string `json:"weight_hash,omitempty"` // SHA-256 fingerprint of weight files
	// IsVision is true when the provider can serve this build with image/video
	// input (a VLM, detected via vision_config). v0.6.0+ only; older providers omit
	// it (decodes to false) so they are never selected for media requests. The
	// coordinator uses this purely for routing — the public input-modalities a
	// consumer sees are governed separately by the catalog capabilities, so this
	// advertisement does not by itself light up vision in the API.
	IsVision bool `json:"is_vision,omitempty"`
	// TemplateRenderOK is set by 0.6.5+ providers after rendering the model's
	// chat template against canonical fixtures (tool schemas with nullable or
	// missing types, multimodal content parts). false means the template render
	// CRASHES on those shapes (e.g. Gemma's "upper filter requires string" on
	// OpenAI tool schemas) and the provider must be excluded from tool-bearing
	// requests for this model. nil means a pre-0.6.5 provider with no opinion
	// (allowed, subject to capability version floors). Pointer + omitempty so
	// explicit false SURVIVES the wire — false is the exclusion signal, while
	// nil is omitted entirely.
	TemplateRenderOK *bool `json:"template_render_ok,omitempty"`
	// ToolConstraintTemplateHash binds inference-time grammar capability to the
	// exact chat-template bytes the provider loaded. It is informational unless
	// the provider also advertises the model under tool_constraint_models.
	ToolConstraintTemplateHash string `json:"tool_constraint_template_hash,omitempty"`
}

// LoadModelMessage instructs a provider to eagerly load (and pin in
// GPU memory) a model that the coordinator anticipates demand for.
// Providers receive it on the existing WebSocket connection (no new
// inbound port required) and reply asynchronously with a
// LoadModelStatusMessage when the load completes or fails.
//
// This is sent only to providers running the Swift runtime
// (`backend == "mlx-swift"`); the coordinator filters by backend
// accordingly.
type LoadModelMessage struct {
	Type    string `json:"type"`
	ModelID string `json:"model_id"`
}

// LoadModelStatusMessage is the provider's reply to a LoadModelMessage.
// Status is one of LoadModelStatusStarted, LoadModelStatusSucceeded,
// LoadModelStatusFailed. On failure, Error carries a human-readable
// reason (e.g. "model not in local cache", "GPU OOM").
type LoadModelStatusMessage struct {
	Type    string `json:"type"`
	ModelID string `json:"model_id"`
	Status  string `json:"status"`
	Error   string `json:"error,omitempty"`
}

// PrefetchModelMessage instructs a provider to download AND verify a model
// build in the background WITHOUT loading it into GPU memory and without
// disrupting whatever model it is currently serving. It is the transport
// for zero-downtime model migrations: the coordinator tells a provider to
// fetch the new build ahead of time, then flips routing once the provider
// reports the build verified-on-disk.
//
// Priority is an advisory hint (higher = more urgent); the provider may use
// it to order concurrent prefetches. Sent only to Swift-runtime providers.
type PrefetchModelMessage struct {
	Type     string `json:"type"`
	ModelID  string `json:"model_id"`
	Priority int    `json:"priority,omitempty"`
}

// DesiredModelEntry declares, for one public model name (alias), the build the
// coordinator wants this provider to converge to. DesiredBuild is a single
// pointer (no weights). PreviousBuild (if set) stays acceptable to serve during
// a staggered rollout so a not-yet-swapped provider keeps serving.
type DesiredModelEntry struct {
	ModelName     string `json:"model_name"`               // clean/public alias, e.g. "gemma-4-26b"
	DesiredBuild  string `json:"desired_build"`            // concrete build id to converge to
	PreviousBuild string `json:"previous_build,omitempty"` // still-acceptable build mid-rollout
}

// DesiredModelsMessage is the coordinator's declarative statement of the desired
// build per public model name. Sent once right after register and again whenever
// a desired build changes. The provider reconciles: background-prefetch (resumable)
// any missing desired build, then hard-swap and emit models_update once verified.
//
// This is sent only to providers running the Swift runtime (backend ==
// "mlx-swift") at or above the version that understands it; the coordinator
// filters accordingly, because a pre-feature provider's strict decoder throws on
// unknown message types.
type DesiredModelsMessage struct {
	Type   string              `json:"type"`
	Models []DesiredModelEntry `json:"models"`
}

// ModelsUpdateMessage is an authoritative, out-of-band update to the provider's
// advertised model inventory. A provider sends it after a coordinator-driven
// prefetch is downloaded AND verified on disk, carrying the full ModelInfo
// (including the computed weight hash) for the newly-available build. The
// coordinator cross-checks each WeightHash against the catalog before merging,
// so a verified build becomes routable immediately — without the disruption of
// a full re-register (which would reset reputation and restart the challenge
// loop) and without bypassing weight-hash verification. Current providers also
// refresh concrete-model tool-constraint capability; legacy updates omit it.
type ModelsUpdateMessage struct {
	Type                   string      `json:"type"`
	Models                 []ModelInfo `json:"models"`
	ToolConstraintProtocol int         `json:"tool_constraint_protocol,omitempty"`
	ToolConstraintModels   []string    `json:"tool_constraint_models,omitempty"`
}

// PrefetchModelStatusMessage is the provider's progress/terminal reply to a
// PrefetchModelMessage. Status is one of PrefetchModelStatusStarted,
// PrefetchModelStatusDownloading, PrefetchModelStatusVerified,
// PrefetchModelStatusFailed. BytesDone/BytesTotal report download progress
// (best-effort; may be 0 when unknown). On failure, Error carries a
// human-readable reason.
type PrefetchModelStatusMessage struct {
	Type       string `json:"type"`
	ModelID    string `json:"model_id"`
	Status     string `json:"status"`
	BytesDone  int64  `json:"bytes_done,omitempty"`
	BytesTotal int64  `json:"bytes_total,omitempty"`
	Error      string `json:"error,omitempty"`
}
