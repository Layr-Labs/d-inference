package store

import (
	"encoding/json"
	"fmt"
	"sort"
	"time"
)

// --- Model Registry ---

func (s *MemoryStore) UpsertModelRegistryEntry(entry *ModelRegistryEntry) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	cp := cloneModelRegistryEntry(entry)
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

func (s *MemoryStore) SetModelVersion(entry *ModelRegistryEntry, version *ModelVersion, files []ModelVersionFile) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	entryCopy := cloneModelRegistryEntry(entry)
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
		if versionCopy.UploadedAt.IsZero() {
			versionCopy.UploadedAt = existing.UploadedAt
		}
		versionCopy.PromotedAt = cloneTimePtr(existing.PromotedAt)
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
	version.UploadedAt = versionCopy.UploadedAt

	fileCopies := make([]ModelVersionFile, len(files))
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
	if !ok {
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

func (s *MemoryStore) ListActiveModelRegistry() []ModelRegistryRecord {
	records, _ := s.ListActiveModelRegistryWithError()
	return records
}

func (s *MemoryStore) ListActiveModelRegistryWithError() ([]ModelRegistryRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]ModelRegistryRecord, 0, len(s.activeModelVersion))
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

func (s *MemoryStore) GetModelRegistryRecord(modelID string) (*ModelRegistryRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rec := s.modelRegistryRecordLocked(modelID)
	if rec == nil {
		return nil, fmt.Errorf("model %q not found", modelID)
	}
	return rec, nil
}

func (s *MemoryStore) GetModelManifest(modelID string) (*ModelManifest, error) {
	rec, err := s.GetModelRegistryRecord(modelID)
	if err != nil {
		return nil, err
	}
	return manifestFromRecord(rec), nil
}

func (s *MemoryStore) UpsertPublishingAPIKey(key *PublishingAPIKey) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *key
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}
	cp.LastUsedAt = cloneTimePtr(key.LastUsedAt)
	s.publishingAPIKeys[key.ID] = &cp
	return nil
}

func (s *MemoryStore) FindPublishingAPIKeys() []PublishingAPIKey {
	keys, _ := s.FindPublishingAPIKeysWithError()
	return keys
}

func (s *MemoryStore) FindPublishingAPIKeysWithError() ([]PublishingAPIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	keys := make([]PublishingAPIKey, 0, len(s.publishingAPIKeys))
	for _, key := range s.publishingAPIKeys {
		cp := *key
		cp.LastUsedAt = cloneTimePtr(key.LastUsedAt)
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

func (s *MemoryStore) modelRegistryRecordLocked(modelID string) *ModelRegistryRecord {
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
	entryCopy := cloneModelRegistryEntry(entry)
	versionCopy := cloneModelVersion(version)
	files := append([]ModelVersionFile(nil), s.modelVersionFiles[versionID]...)
	return &ModelRegistryRecord{ModelRegistryEntry: entryCopy, ActiveVersion: &versionCopy, Files: files}
}

func modelVersionKey(modelID, version string) string {
	return modelID + "\x00" + version
}

func cloneModelRegistryEntry(entry *ModelRegistryEntry) ModelRegistryEntry {
	if entry == nil {
		return ModelRegistryEntry{}
	}
	cp := *entry
	cp.Capabilities = append([]string(nil), entry.Capabilities...)
	cp.RuntimeParameters = cloneMetadata(entry.RuntimeParameters)
	cp.Metadata = cloneMetadata(entry.Metadata)
	return cp
}

func cloneModelVersion(version *ModelVersion) ModelVersion {
	if version == nil {
		return ModelVersion{}
	}
	cp := *version
	cp.PromotedAt = cloneTimePtr(version.PromotedAt)
	cp.Metadata = cloneMetadata(version.Metadata)
	return cp
}

func cloneMetadata(metadata map[string]any) map[string]any {
	if metadata == nil {
		return map[string]any{}
	}
	data, err := json.Marshal(metadata)
	if err != nil {
		return map[string]any{}
	}
	out := map[string]any{}
	if err := json.Unmarshal(data, &out); err != nil {
		return map[string]any{}
	}
	return out
}
