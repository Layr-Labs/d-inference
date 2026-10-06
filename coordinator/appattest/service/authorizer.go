package service

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Service) newAuthorizer() *authorization.Controller {
	return authorization.New(authorization.Dependencies{
		Registry:      s.registry,
		Notifications: s.notifications,
		Readiness: func() store.AppAttestReadinessBatchStore {
			st, _ := store.As[store.AppAttestReadinessBatchStore](s.store)
			return st
		},
		ReleasePolicy: s.currentReleasePolicySnapshot,
		Qualify:       s.applyBuildQualification,
		Notify:        s.sendAppAttestAuthorizationStatus,
		Revoke:        s.RevokeCredential,
		Count:         func(name string) { s.ddIncr(name, nil) },
	})
}

func (s *Service) startAppAttestAuthorizer(ctx context.Context) {
	if !s.config.ServingEnabled || s.config.Environment != "production" {
		return
	}
	if s.notifications == nil {
		s.notifications = authorization.NewOutbox(256)
	}
	a := s.newAuthorizer()
	s.authorizer = a
	_, generation := s.registry.AppAttestServingPolicy()
	s.registry.SetAppAttestServingPolicy(true, generation)
	a.Start(ctx, func(name string, run func()) { saferun.Go(s.logger, name, run) })
}
