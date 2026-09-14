package memory

import (
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/recordutil"
)

func (s *Store) UpsertModelRegistryEntry(entry *contracts.ModelRegistryEntry) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	cp := recordutil.CloneModelRegistryEntry(entry)
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

func (s *Store) SetModelVersion(entry *contracts.ModelRegistryEntry, version *contracts.ModelVersion, files []contracts.ModelVersionFile) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	entryCopy := recordutil.CloneModelRegistryEntry(entry)
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
	versionCopy := recordutil.CloneModelVersion(version)
	if existing, ok := s.modelVersions[key]; ok {
		versionCopy.ID = existing.ID
		if versionCopy.UploadedAt.IsZero() {
			versionCopy.UploadedAt = existing.UploadedAt
		}
		versionCopy.PromotedAt = recordutil.CloneTimePtr(existing.PromotedAt)
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

	fileCopies := make([]contracts.ModelVersionFile, len(files))
	for i := range files {
		fileCopies[i] = files[i]
		fileCopies[i].ID = int64(i + 1)
		fileCopies[i].ModelVersionID = versionCopy.ID
	}
	s.modelVersionFiles[versionCopy.ID] = fileCopies
	return nil
}

func (s *Store) PromoteModelVersion(modelID, version string) error {
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

func (s *Store) SetModelStatus(modelID, status string) error {
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

func (s *Store) ListActiveModelRegistry() []contracts.ModelRegistryRecord {
	records, _ := s.ListActiveModelRegistryWithError()
	return records
}

func (s *Store) ListActiveModelRegistryWithError() ([]contracts.ModelRegistryRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]contracts.ModelRegistryRecord, 0, len(s.activeModelVersion))
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

func (s *Store) GetModelRegistryRecord(modelID string) (*contracts.ModelRegistryRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rec := s.modelRegistryRecordLocked(modelID)
	if rec == nil {
		return nil, fmt.Errorf("model %q %w", modelID, contracts.ErrNotFound)
	}
	return rec, nil
}

func (s *Store) GetModelManifest(modelID string) (*contracts.ModelManifest, error) {
	rec, err := s.GetModelRegistryRecord(modelID)
	if err != nil {
		return nil, err
	}
	return recordutil.ManifestFromRecord(rec), nil
}

func (s *Store) UpsertPublishingAPIKey(key *contracts.PublishingAPIKey) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cp := *key
	if cp.CreatedAt.IsZero() {
		cp.CreatedAt = time.Now()
	}
	cp.LastUsedAt = recordutil.CloneTimePtr(key.LastUsedAt)
	s.publishingAPIKeys[key.ID] = &cp
	return nil
}

func (s *Store) FindPublishingAPIKeys() []contracts.PublishingAPIKey {
	keys, _ := s.FindPublishingAPIKeysWithError()
	return keys
}

func (s *Store) FindPublishingAPIKeysWithError() ([]contracts.PublishingAPIKey, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	keys := make([]contracts.PublishingAPIKey, 0, len(s.publishingAPIKeys))
	for _, key := range s.publishingAPIKeys {
		cp := *key
		cp.LastUsedAt = recordutil.CloneTimePtr(key.LastUsedAt)
		keys = append(keys, cp)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i].CreatedAt.Before(keys[j].CreatedAt) })
	return keys, nil
}

func (s *Store) MarkPublishingAPIKeyUsed(id string) error {
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

func (s *Store) modelRegistryRecordLocked(modelID string) *contracts.ModelRegistryRecord {
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
	entryCopy := recordutil.CloneModelRegistryEntry(entry)
	versionCopy := recordutil.CloneModelVersion(version)
	files := append([]contracts.ModelVersionFile(nil), s.modelVersionFiles[versionID]...)
	return &contracts.ModelRegistryRecord{ModelRegistryEntry: entryCopy, ActiveVersion: &versionCopy, Files: files}
}

func modelVersionKey(modelID, version string) string {
	return modelID + "\x00" + version
}
