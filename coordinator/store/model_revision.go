package store

import "errors"

// ErrModelVersionImmutable prevents a published version from changing underneath
// downloads, loaded engines, attestation, or rollback. Publish a new version.
var ErrModelVersionImmutable = errors.New("model version is immutable; publish a new version")

// ErrModelVersionRetired prevents retries from reviving a revoked artifact.
var ErrModelVersionRetired = errors.New("model revision is retired; publish a new version")

// ErrActiveModelVersion requires selecting a replacement before revocation.
var ErrActiveModelVersion = errors.New("cannot retire the active model revision; promote a replacement first")

func sameModelVersionFiles(a, b []ModelVersionFile) bool {
	if len(a) != len(b) {
		return false
	}
	byPath := make(map[string]ModelVersionFile, len(a))
	for _, f := range a {
		byPath[f.Path] = f
	}
	for _, f := range b {
		old, ok := byPath[f.Path]
		if !ok || old.SizeBytes != f.SizeBytes || old.SHA256 != f.SHA256 || old.Role != f.Role {
			return false
		}
		delete(byPath, f.Path)
	}
	return len(byPath) == 0
}

func (s *MemoryStore) RetireModelVersion(modelID, version string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	v := s.modelVersions[modelVersionKey(modelID, version)]
	if v == nil {
		return ErrNotFound
	}
	if s.activeModelVersion[modelID] == v.ID {
		return ErrActiveModelVersion
	}
	v.Status = "retired"
	return nil
}
