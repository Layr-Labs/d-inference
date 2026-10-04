package memory

import (
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) UpsertModelRegistryEntry(entry *store.ModelRegistryEntry) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	cp := shared.CloneModelRegistryEntry(entry)
	if existing, ok := s.modelRegistry[entry.ID]; ok && !existing.CreatedAt.IsZero() {
		cp.CreatedAt = existing.CreatedAt
		cp.Status = existing.Status
	} else if cp.CreatedAt.IsZero() {
		cp.CreatedAt = now
	}
	if cp.UpdatedAt.IsZero() {
		cp.UpdatedAt = now
	}
	s.modelRegistry[entry.ID] = &cp
	return nil
}

func (s *MemoryStore) SetModelVersion(entry *store.ModelRegistryEntry, version *store.ModelVersion, files []store.ModelVersionFile) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.setModelVersionLocked(entry, version, files, false)
}

func (s *MemoryStore) SetExistingModelVersion(version *store.ModelVersion, files []store.ModelVersionFile) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	entry := s.modelRegistry[version.ModelID]
	if entry == nil || s.modelRegistryRecordLocked(version.ModelID) == nil {
		return store.ErrNotFound
	}
	return s.setModelVersionLocked(entry, version, files, true)
}

func (s *MemoryStore) setModelVersionLocked(entry *store.ModelRegistryEntry, version *store.ModelVersion, files []store.ModelVersionFile, preserveExistingSource bool) error {

	if old := s.modelVersions[modelVersionKey(version.ModelID, version.Version)]; old != nil &&
		(old.AggregateSHA256 != version.AggregateSHA256 || old.R2Prefix != version.R2Prefix ||
			old.TotalSizeBytes != version.TotalSizeBytes || old.FileCount != version.FileCount ||
			!shared.SameModelVersionFiles(s.modelVersionFiles[old.ID], files)) {
		return store.ErrModelVersionImmutable
	}
	now := time.Now()
	entryCopy := shared.CloneModelRegistryEntry(entry)
	if existing, ok := s.modelRegistry[entry.ID]; ok && !existing.CreatedAt.IsZero() {
		entryCopy.CreatedAt = existing.CreatedAt
		entryCopy.Status = existing.Status
	} else if entryCopy.CreatedAt.IsZero() {
		entryCopy.CreatedAt = now
	}
	if entryCopy.UpdatedAt.IsZero() {
		entryCopy.UpdatedAt = now
	}
	s.modelRegistry[entry.ID] = &entryCopy

	key := modelVersionKey(version.ModelID, version.Version)
	versionCopy := cloneModelVersion(version)
	if existing, ok := s.modelVersions[key]; ok {
		versionCopy.ID = existing.ID
		// Re-registration must not undo an explicit retirement, including when
		// a later promotion fails or the coordinator restarts before syncing.
		if existing.Status == "retired" {
			versionCopy.Status = "retired"
		}
		// Identical publication retries retain the first publisher's audit
		// identity, even when a different credential replays the manifest.
		versionCopy.UploadedBy = existing.UploadedBy
		versionCopy.UploadedAt = existing.UploadedAt
		if preserveExistingSource {
			// A revision replay must not undo a later explicit mirror edit via
			// full registration, which still supports add/change/clear.
			versionCopy.HuggingFaceArtifact = store.CloneHuggingFaceArtifact(existing.HuggingFaceArtifact)
		}
		versionCopy.PromotedAt = store.CloneTimePtr(existing.PromotedAt)
	} else {
		s.modelVersionSeq++
		versionCopy.ID = s.modelVersionSeq
	}
	if versionCopy.UploadedAt.IsZero() {
		versionCopy.UploadedAt = now
	}
	s.modelVersions[key] = &versionCopy
	s.modelVersionByID[versionCopy.ID] = &versionCopy
	version.ID = versionCopy.ID
	version.UploadedBy = versionCopy.UploadedBy
	version.UploadedAt = versionCopy.UploadedAt
	version.Status = versionCopy.Status
	version.HuggingFaceArtifact = store.CloneHuggingFaceArtifact(versionCopy.HuggingFaceArtifact)

	fileCopies := make([]store.ModelVersionFile, len(files))
	for i := range files {
		fileCopies[i] = files[i]
		fileCopies[i].ID = int64(i + 1)
		fileCopies[i].ModelVersionID = versionCopy.ID
	}
	s.modelVersionFiles[versionCopy.ID] = fileCopies
	return nil
}

func (s *MemoryStore) PromoteModelVersion(modelID, version string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	v, ok := s.modelVersions[modelVersionKey(modelID, version)]
	if ok && v.Status == "retired" {
		return store.ErrModelVersionRetired
	}
	if !ok || v.Status != "ready" {
		return fmt.Errorf("model version %q %q not found", modelID, version)
	}
	now := time.Now()
	v.PromotedAt = &now
	s.activeModelVersion[modelID] = v.ID
	return nil
}

func (s *MemoryStore) SetModelStatus(modelID, status string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	entry, ok := s.modelRegistry[modelID]
	if !ok {
		return fmt.Errorf("model %q not found", modelID)
	}
	entry.Status = status
	entry.UpdatedAt = time.Now()
	return nil
}

func (s *MemoryStore) ListActiveModelRegistryWithError() ([]store.ModelRegistryRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]store.ModelRegistryRecord, 0, len(s.activeModelVersion))
	for modelID := range s.activeModelVersion {
		if rec := s.modelRegistryRecordLocked(modelID); rec != nil {
			records = append(records, *rec)
		}
	}
	sort.Slice(records, func(i, j int) bool {
		if records[i].MinRAMGB == records[j].MinRAMGB {
			return records[i].ID < records[j].ID
		}
		return records[i].MinRAMGB < records[j].MinRAMGB
	})
	return records, nil
}

func (s *MemoryStore) GetModelRegistryRecord(modelID string) (*store.ModelRegistryRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rec := s.modelRegistryRecordLocked(modelID)
	if rec == nil {
		return nil, fmt.Errorf("model %q %w", modelID, store.ErrNotFound)
	}
	return rec, nil
}

func (s *MemoryStore) GetModelManifest(modelID string) (*store.ModelManifest, error) {
	rec, err := s.GetModelRegistryRecord(modelID)
	if err != nil {
		return nil, err
	}
	return store.ManifestFromRecord(rec), nil
}

func (s *MemoryStore) FindPublishingAPIKeysWithError() ([]store.PublishingAPIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	keys := make([]store.PublishingAPIKey, 0, len(s.publishingAPIKeys))
	for _, key := range s.publishingAPIKeys {
		cp := *key
		cp.LastUsedAt = store.CloneTimePtr(key.LastUsedAt)
		keys = append(keys, cp)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i].CreatedAt.Before(keys[j].CreatedAt) })
	return keys, nil
}

func (s *MemoryStore) MarkPublishingAPIKeyUsed(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key, ok := s.publishingAPIKeys[id]
	if !ok {
		return fmt.Errorf("publishing API key %q not found", id)
	}
	now := time.Now()
	key.LastUsedAt = &now
	return nil
}

func cloneModelAlias(a *store.ModelAlias) store.ModelAlias {
	cp := *a
	// RetiredBuilds is the only reference-typed field; copy it so callers can't
	// mutate stored state through the returned value.
	if a.RetiredBuilds != nil {
		cp.RetiredBuilds = append([]string(nil), a.RetiredBuilds...)
	}
	return cp
}

func (s *MemoryStore) UpsertModelAlias(alias *store.ModelAlias) error {
	if alias == nil || alias.AliasID == "" {
		return fmt.Errorf("model alias requires a non-empty alias_id")
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	cp := cloneModelAlias(alias)
	if existing, ok := s.modelAliases[alias.AliasID]; ok && !existing.CreatedAt.IsZero() {
		cp.CreatedAt = existing.CreatedAt
	} else if cp.CreatedAt.IsZero() {
		cp.CreatedAt = now
	}
	cp.UpdatedAt = now
	s.modelAliases[alias.AliasID] = &cp
	return nil
}

func (s *MemoryStore) GetModelAlias(aliasID string) (*store.ModelAlias, bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	a, ok := s.modelAliases[aliasID]
	if !ok {
		return nil, false, nil
	}
	cp := cloneModelAlias(a)
	return &cp, true, nil
}

func (s *MemoryStore) ListModelAliases() ([]store.ModelAlias, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]store.ModelAlias, 0, len(s.modelAliases))
	for _, a := range s.modelAliases {
		out = append(out, cloneModelAlias(a))
	}
	sort.Slice(out, func(i, j int) bool { return out[i].AliasID < out[j].AliasID })
	return out, nil
}

func (s *MemoryStore) DeleteModelAlias(aliasID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	delete(s.modelAliases, aliasID)
	return nil
}

func (s *MemoryStore) modelRegistryRecordLocked(modelID string) *store.ModelRegistryRecord {
	entry, ok := s.modelRegistry[modelID]
	if !ok || (entry.Status != "active" && entry.Status != "beta") {
		return nil
	}
	versionID, ok := s.activeModelVersion[modelID]
	if !ok {
		return nil
	}
	version, ok := s.modelVersionByID[versionID]
	if !ok || version.Status != "ready" {
		return nil
	}
	entryCopy := shared.CloneModelRegistryEntry(entry)
	versionCopy := cloneModelVersion(version)
	files := append([]store.ModelVersionFile(nil), s.modelVersionFiles[versionID]...)
	rec := &store.ModelRegistryRecord{ModelRegistryEntry: entryCopy, ActiveVersion: &versionCopy, Files: files}
	for _, candidate := range s.modelVersions {
		if candidate.ModelID == modelID && candidate.PromotedAt != nil && candidate.Status == "ready" {
			rec.ServingVersions = append(rec.ServingVersions, cloneModelVersion(candidate))
		}
	}
	sort.Slice(rec.ServingVersions, func(i, j int) bool { return rec.ServingVersions[i].Version < rec.ServingVersions[j].Version })
	return rec
}

func modelVersionKey(modelID, version string) string {
	return modelID + "\x00" + version
}

func cloneModelVersion(version *store.ModelVersion) store.ModelVersion {
	if version == nil {
		return store.ModelVersion{}
	}
	cp := *version
	cp.PromotedAt = store.CloneTimePtr(version.PromotedAt)
	cp.HuggingFaceArtifact = store.CloneHuggingFaceArtifact(version.HuggingFaceArtifact)
	cp.Metadata = shared.CloneMetadata(version.Metadata)
	return cp
}
