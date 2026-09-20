package service

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const BuildQualificationFreshness = 30 * time.Second

type buildQualificationSnapshot struct {
	generation uint64
	observedAt time.Time
	builds     map[string]store.AppAttestBuildQualification
}

// RefreshBuildQualifications serializes reads with local revocation fencing.
// An unavailable store never extends the previous snapshot's lease deadline.
func (s *Service) RefreshBuildQualifications(ctx context.Context) error {
	s.qualificationMu.Lock()
	defer s.qualificationMu.Unlock()
	st, ok := store.As[store.AppAttestBuildStore](s.store)
	if !ok {
		return errors.New("build qualification storage unavailable")
	}
	observed := time.Now().UTC()
	rows, err := st.ListAppAttestBuildQualifications(ctx)
	if err != nil {
		return err
	}
	builds := make(map[string]store.AppAttestBuildQualification, len(rows))
	for _, q := range rows {
		builds[q.Release.BinaryHash] = q
	}
	s.publishBuildQualifications(builds, observed)
	return nil
}

// Caller holds qualificationMu. Fence registry grants BEFORE publishing the
// new immutable view, so a concurrent verifier cannot reinstall an old lease.
func (s *Service) publishBuildQualifications(builds map[string]store.AppAttestBuildQualification, observed time.Time) {
	old := s.qualifications.Load()
	generation := uint64(1)
	if old != nil {
		generation = old.generation
		if !reflect.DeepEqual(old.builds, builds) {
			generation++
		}
	}
	if s.registry != nil {
		s.registry.SetAppAttestQualificationGeneration(generation)
	}
	s.qualifications.Store(&buildQualificationSnapshot{generation: generation, observedAt: observed, builds: builds})
}

// FenceBuild is called after a durable revocation commit. It needs no further
// database read and preserves the age of every other build's cached evidence.
func (s *Service) FenceBuild(binary string) {
	s.qualificationMu.Lock()
	defer s.qualificationMu.Unlock()
	builds := map[string]store.AppAttestBuildQualification{}
	observed := time.Time{}
	if old := s.qualifications.Load(); old != nil {
		observed = old.observedAt
		for hash, q := range old.builds {
			builds[hash] = q
		}
	}
	q := builds[binary]
	q.Release.BinaryHash, q.RevokedAt = binary, time.Now().UTC()
	builds[binary] = q
	s.publishBuildQualifications(builds, observed)
}

func (s *Service) startBuildQualifications(ctx context.Context) {
	refresh := func() {
		op, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		if err := s.RefreshBuildQualifications(op); err != nil {
			s.ddIncr("app_attest.qualification.refresh_failed", nil)
		}
		if s.config.ServingEnabled && s.refreshReleasePolicy != nil {
			if err := s.refreshReleasePolicy(); err != nil {
				s.ddIncr("app_attest.release_refresh_failed", nil)
			}
		}
	}
	refresh()
	saferun.Go(s.logger, "appAttestBuildQualifications", func() {
		ticker := time.NewTicker(appAttestAuthorizationRefresh)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				refresh()
			}
		}
	})
}

// Re-evaluate qualification on EVERY lease refresh, using only the measurement
// parsed from verified Apple metadata. Cached match booleans are not evidence.
func (s *Service) applyBuildQualification(e *appattest.AuthorizationEvidence, status *protocol.AppAttestStatus, catalog *ReleasePolicy) (uint64, time.Time) {
	e.BuildQualified, e.CodeMeasurementKnown, e.CodeMeasurementMatched = false, false, false
	snapshot := s.qualifications.Load()
	if snapshot == nil || status == nil {
		return 0, time.Time{}
	}
	until := snapshot.observedAt.Add(BuildQualificationFreshness)
	if !until.After(time.Now()) {
		return snapshot.generation, until
	}
	if q, exists := snapshot.builds[status.BinaryHash]; exists {
		if q.RevokedAt.IsZero() && q.AppAttestBuildIdentity.Validate() == nil &&
			q.Release.Version == status.AppVersion && q.Release.Platform == "macos-arm64" {
			e.BuildQualified = catalog != nil && catalog.Known && catalog.ContainsQualifiedRelease != nil && catalog.ContainsQualifiedRelease(q.Release)
			e.CodeMeasurementKnown = appAttestSHA256Hex(e.CodeDirectoryHash)
			e.CodeMeasurementMatched = e.CodeMeasurementKnown && e.CodeDirectoryHash == q.CodeDirectoryHash
		}
	} else {
		// Compatibility for already-qualified deployments only. Durable rows,
		// including tombstones, always override env; unavailable storage denies
		// both. New releases MUST carry durable qualification to be published.
		e.BuildQualified = qualifiedAppAttestBuild(s.config.QualifiedBuildHashes, status.BinaryHash)
		e.CodeMeasurementKnown, e.CodeMeasurementMatched = qualifiedAppAttestCode(s.config.QualifiedCodeHashes, status.BinaryHash, e.CodeDirectoryHash)
	}
	return snapshot.generation, until
}

// Publication requires the durable record, never the compatibility env list.
func (s *Service) BuildReady(b store.AppAttestBuildIdentity) bool {
	snapshot := s.qualifications.Load()
	if snapshot == nil || !snapshot.observedAt.Add(BuildQualificationFreshness).After(time.Now()) {
		return false
	}
	q, ok := snapshot.builds[b.Release.BinaryHash]
	return ok && q.RevokedAt.IsZero() && q.Matches(b) && q.AppAttestBuildIdentity.Validate() == nil
}

// ReleaseReady guards even cached download responses. A durable revocation
// takes precedence over startup compatibility settings and cached HTTP JSON.
func (s *Service) ReleaseReady(r store.Release) bool {
	snapshot := s.qualifications.Load()
	if snapshot == nil || !snapshot.observedAt.Add(BuildQualificationFreshness).After(time.Now()) {
		return false
	}
	if q, ok := snapshot.builds[r.BinaryHash]; ok {
		b := q.AppAttestBuildIdentity
		b.Release = r
		return q.RevokedAt.IsZero() && q.Matches(b) && b.Validate() == nil
	}
	if !qualifiedAppAttestBuild(s.config.QualifiedBuildHashes, r.BinaryHash) {
		return false
	}
	for _, pair := range strings.Split(s.config.QualifiedCodeHashes, ",") {
		binary, code, ok := strings.Cut(strings.TrimSpace(pair), ":")
		if ok && binary == r.BinaryHash {
			_, matched := qualifiedAppAttestCode(s.config.QualifiedCodeHashes, binary, code)
			return matched
		}
	}
	return false
}
