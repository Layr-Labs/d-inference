package store

import "time"

// SupportedModel is the lightweight in-memory shape the model-listing and
// routing code uses to describe a servable model. It is derived from the
// canonical model_registry (see supportedModelFromRegistryRecord); it is no
// longer a standalone persisted catalog. The coordinator remains the single
// source of truth for which models providers can serve.
//
// ModelType determines routing: "text" for chat/completions, "embedding" for
// vector search, etc.
type SupportedModel struct {
	ID           string  `json:"id"`           // HuggingFace path (e.g. "mlx-community/Qwen3.5-9B-MLX-4bit")
	S3Name       string  `json:"s3_name"`      // CDN key for download (e.g. "Qwen3.5-9B-MLX-4bit")
	DisplayName  string  `json:"display_name"` // Human-readable (e.g. "Qwen3.5 9B")
	ModelType    string  `json:"model_type"`   // "text", "embedding", "tts"
	SizeGB       float64 `json:"size_gb"`      // Disk/memory size in GB
	Architecture string  `json:"architecture"` // e.g. "9B dense", "2B conformer"
	Description  string  `json:"description"`  // e.g. "Balanced", "Fast reasoning"
	MinRAMGB     int     `json:"min_ram_gb"`   // Minimum system RAM for auto-selection
	Active       bool    `json:"active"`       // Whether available for use
	WeightHash   string  `json:"weight_hash"`  // Expected SHA-256 fingerprint of model weight files
}

// ModelRegistryEntry is the canonical admin-managed model catalog row.
type ModelRegistryEntry struct {
	ID                string         `json:"id"`
	DisplayName       string         `json:"display_name"`
	Family            string         `json:"family"`
	Architecture      string         `json:"architecture"`
	Quantization      string         `json:"quantization"`
	MaxContextLength  int            `json:"max_context_length"`
	MaxOutputLength   int            `json:"max_output_length"`
	MinRAMGB          int            `json:"min_ram_gb"`
	Capabilities      []string       `json:"capabilities"`
	Status            string         `json:"status"`
	Description       string         `json:"description"`
	RuntimeParameters map[string]any `json:"runtime_parameters"`
	Metadata          map[string]any `json:"metadata"`
	CreatedAt         time.Time      `json:"created_at"`
	UpdatedAt         time.Time      `json:"updated_at"`
}

// ModelVersion is an uploaded manifest version for a registered model.
type ModelVersion struct {
	ID              int64          `json:"id"`
	ModelID         string         `json:"model_id"`
	Version         string         `json:"version"`
	R2Prefix        string         `json:"r2_prefix"`
	AggregateSHA256 string         `json:"aggregate_sha256"`
	TotalSizeBytes  int64          `json:"total_size_bytes"`
	FileCount       int            `json:"file_count"`
	Status          string         `json:"status"`
	UploadedBy      string         `json:"uploaded_by,omitempty"`
	UploadedAt      time.Time      `json:"uploaded_at"`
	PromotedAt      *time.Time     `json:"promoted_at,omitempty"`
	Metadata        map[string]any `json:"metadata"`
}

// ModelVersionFile is one file in a model version manifest.
type ModelVersionFile struct {
	ID             int64  `json:"id"`
	ModelVersionID int64  `json:"model_version_id"`
	Path           string `json:"path"`
	SizeBytes      int64  `json:"size_bytes"`
	SHA256         string `json:"sha256"`
	Role           string `json:"role"`
}

// ModelRegistryRecord combines a model with its active version and files.
type ModelRegistryRecord struct {
	ModelRegistryEntry
	ActiveVersion *ModelVersion      `json:"active_version,omitempty"`
	Files         []ModelVersionFile `json:"files,omitempty"`
}

// ModelAlias is a stable, consumer-facing model name (e.g. "gemma-4-26b") that
// resolves to a single DESIRED concrete registry build (a raw HuggingFace id
// such as "mlx-community/gemma-4-26B-A4B-it-qat-4bit"), with an optional
// PreviousBuild that stays acceptable while providers converge on the desired
// one. Consumers only ever see the alias; the coordinator resolves it to a
// concrete build for routing/billing. This is what makes a quant swap
// (fp8 → qat-4bit) invisible to clients: a rollout is just setting DesiredBuild,
// a revert is setting it back. There are no weights, ramps, or migrations.
type ModelAlias struct {
	AliasID       string `json:"alias_id"`
	DisplayName   string `json:"display_name"`
	DesiredBuild  string `json:"desired_build"`            // the single build providers should converge to
	PreviousBuild string `json:"previous_build,omitempty"` // still-acceptable during rollout; "" when none
	// RetiredBuilds is the alias's lineage: former desired/previous builds
	// rotated out by later upserts. Kept so a provider that was offline through
	// a retirement (still advertising only a retired build) is recognized as
	// part of this alias's fleet at re-registration and told to converge. A
	// build promoted back to desired/previous leaves this list. Bounded; oldest
	// entries dropped first.
	RetiredBuilds []string  `json:"retired_builds,omitempty"`
	Active        bool      `json:"active"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// ModelManifest mirrors the minimal darkbloom-publish manifest JSON.
type ModelManifest struct {
	SchemaVersion   int            `json:"schema_version"`
	ModelID         string         `json:"model_id"`
	Version         string         `json:"version"`
	R2Prefix        string         `json:"r2_prefix"`
	AggregateSHA256 string         `json:"aggregate_sha256"`
	TotalSizeBytes  int64          `json:"total_size_bytes"`
	FileCount       int            `json:"file_count"`
	Files           []ManifestFile `json:"files"`
	CreatedAt       time.Time      `json:"created_at"`
}

// ManifestFile mirrors a file entry in a model manifest.
type ManifestFile struct {
	Path      string `json:"path"`
	SizeBytes int64  `json:"size_bytes"`
	SHA256    string `json:"sha256"`
	Role      string `json:"role"`
}

// PublishingAPIKey stores a hashed key allowed to publish model manifests.
type PublishingAPIKey struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	KeyHash    string     `json:"key_hash"`
	Active     bool       `json:"active"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
}
