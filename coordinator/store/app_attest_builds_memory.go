package store

import (
	"context"
	"time"
)

func (s *MemoryStore) ListAppAttestBuildQualifications(ctx context.Context) ([]AppAttestBuildQualification, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]AppAttestBuildQualification, 0, len(s.appAttestBuilds))
	for _, q := range s.appAttestBuilds {
		out = append(out, q)
	}
	return out, nil
}

func (s *MemoryStore) QualifyAppAttestBuild(ctx context.Context, q AppAttestBuildQualification) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if err := q.validateApproval(); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestBuilds == nil {
		s.appAttestBuilds = make(map[string]AppAttestBuildQualification)
	}
	if old, ok := s.appAttestBuilds[q.Release.BinaryHash]; ok {
		if !old.RevokedAt.IsZero() || !old.Matches(q.AppAttestBuildIdentity) {
			return false, ErrBuildConflict
		}
		return false, nil
	}
	q.ApprovedAt = time.Now().UTC()
	s.appAttestBuilds[q.Release.BinaryHash] = q
	return true, nil
}

func (s *MemoryStore) RevokeAppAttestBuild(ctx context.Context, binary, actor, reason string) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if err := validateBuildRevocation(binary, actor, reason); err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.appAttestBuilds == nil {
		s.appAttestBuilds = make(map[string]AppAttestBuildQualification)
	}
	q := s.appAttestBuilds[binary]
	if !q.RevokedAt.IsZero() {
		return false, nil
	}
	q.Release.BinaryHash = binary // Tombstones also override legacy env approvals.
	q.RevokedAt, q.RevokedBy, q.RevocationReason = time.Now().UTC(), actor, reason
	s.appAttestBuilds[binary] = q
	return true, nil
}

func (s *MemoryStore) SetQualifiedRelease(ctx context.Context, b AppAttestBuildIdentity) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if err := b.Validate(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	q, ok := s.appAttestBuilds[b.Release.BinaryHash]
	if !ok || !q.RevokedAt.IsZero() || !q.Matches(b) {
		return ErrBuildNotQualified
	}
	r := b.Release
	key := releaseKey(r.Version, r.Platform)
	if old := s.releases[key]; old != nil {
		if !sameBuildRelease(*old, r) {
			return ErrBuildConflict
		}
		r.CreatedAt = old.CreatedAt
	}
	if r.CreatedAt.IsZero() {
		r.CreatedAt = time.Now().UTC()
	}
	r.Active = true
	s.releases[key] = &r
	return nil
}
