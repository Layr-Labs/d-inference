package service

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/qualification"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const BuildQualificationFreshness = qualification.Freshness

// RefreshBuildQualifications serializes reads with local revocation fencing.
// An unavailable store never extends the previous snapshot's lease deadline.
func (s *Service) RefreshBuildQualifications(ctx context.Context) error {
	st, _ := store.As[store.AppAttestBuildStore](s.store)
	return s.qualifications.Refresh(ctx, st, s.fenceQualificationGeneration)
}

func (s *Service) fenceQualificationGeneration(generation uint64) {
	if s.registry != nil {
		s.registry.SetAppAttestQualificationGeneration(generation)
	}
}

// FenceBuild follows a durable revocation and preserves other evidence's age.
func (s *Service) FenceBuild(binary string) {
	s.qualifications.FenceBuild(binary, s.fenceQualificationGeneration)
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
		ticker := time.NewTicker(authorization.RefreshInterval)
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

func (s *Service) qualificationBootstrap() qualification.Bootstrap {
	return qualification.Bootstrap{BuildHashes: s.config.QualifiedBuildHashes, CodeHashes: s.config.QualifiedCodeHashes}
}

func (s *Service) applyBuildQualification(e *appattest.AuthorizationEvidence, status *protocol.AppAttestStatus, catalog *ReleasePolicy) (uint64, time.Time) {
	var view *qualification.Catalog
	if catalog != nil {
		view = &qualification.Catalog{Known: catalog.Known, ContainsQualifiedRelease: catalog.ContainsQualifiedRelease}
	}
	return s.qualifications.Apply(e, status, view, s.qualificationBootstrap())
}

// Publication requires the durable record, never the compatibility env list.
func (s *Service) BuildReady(b store.AppAttestBuildIdentity) bool {
	return s.qualifications.BuildReady(b)
}

// ReleaseReady guards even cached downloads against revocation and expiry.
func (s *Service) ReleaseReady(r store.Release) bool {
	return s.qualifications.ReleaseReady(r, s.qualificationBootstrap())
}
