package store

import "time"

// ModelRegistryStore covers the manifest-backed model catalog and the
// publishing API keys that may write to it.
type ModelRegistryStore interface {
	UpsertModelRegistryEntry(entry *ModelRegistryEntry) error
	SetModelVersion(entry *ModelRegistryEntry, version *ModelVersion, files []ModelVersionFile) error
	PromoteModelVersion(modelID, version string) error
	SetModelStatus(modelID, status string) error
	ListActiveModelRegistry() []ModelRegistryRecord
	ListActiveModelRegistryWithError() ([]ModelRegistryRecord, error)
	GetModelRegistryRecord(modelID string) (*ModelRegistryRecord, error)
	GetModelManifest(modelID string) (*ModelManifest, error)
	UpsertPublishingAPIKey(key *PublishingAPIKey) error
	FindPublishingAPIKeys() []PublishingAPIKey
	FindPublishingAPIKeysWithError() ([]PublishingAPIKey, error)
	MarkPublishingAPIKeyUsed(id string) error
}

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
