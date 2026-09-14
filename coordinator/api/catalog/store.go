package catalog

import "github.com/eigeninference/d-inference/coordinator/store"

// Store is the persistence surface used by model publishing and discovery.
// Transaction, validation, and record-cache ownership stay in the store layer.
type Store interface {
	ListActiveModelRegistryWithError() ([]store.ModelRegistryRecord, error)
	GetModelRegistryRecord(modelID string) (*store.ModelRegistryRecord, error)
	GetModelManifest(modelID string) (*store.ModelManifest, error)
	UpsertModelRegistryEntry(entry *store.ModelRegistryEntry) error
	SetModelVersion(entry *store.ModelRegistryEntry, version *store.ModelVersion, files []store.ModelVersionFile) error
	PromoteModelVersion(modelID, version string) error
	SetModelStatus(modelID, status string) error
	GetModelPrice(accountID, model string) (inputPrice, outputPrice int64, ok bool)
	SetModelPrice(accountID, model string, inputPrice, outputPrice int64) error
	FindPublishingAPIKeysWithError() ([]store.PublishingAPIKey, error)
	MarkPublishingAPIKeyUsed(id string) error
	GetModelAlias(aliasID string) (alias *store.ModelAlias, ok bool, err error)
	ListModelAliases() ([]store.ModelAlias, error)
	UpsertModelAlias(alias *store.ModelAlias) error
	DeleteModelAlias(aliasID string) error
}
