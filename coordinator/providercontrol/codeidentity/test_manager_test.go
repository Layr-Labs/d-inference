package codeidentity

import (
	"context"
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// testManager adapts the moved owner fixtures without creating the API's
// unrelated workers. Clocks and sender hooks remain private to these tests;
// production callers cannot mutate the Manager's proof or nonce state.
type testManager struct {
	*Manager
	store                         store.Store
	codeResumeSender              func(string, protocol.CodeAttestationResumeChallenge) error
	codeResumeBeforeIdentityCheck func()
	codeResumeFallbackBeforeAPNs  func()
}
type testServerConfig struct{}

func newTestManager(reg *registry.Registry, st store.Store, _ testServerConfig, logger *slog.Logger) *testManager {
	s := &testManager{store: st}
	reg.SetStore(st)
	s.Manager = New(DefaultConfig(), Dependencies{
		Registry: reg, Logger: logger,
		NormalizeHash: normalizeSHA256Hex, ApplicationBinaryHash: providerApplicationBinaryHash,
		ReleasePolicy: func() ReleasePolicy { return nil },
		CoverageStore: func() (CoverageStore, bool) { return store.As[CoverageStore](s.store) },
		Incr:          func(string, []string) {}, Metric: func(string) {},
		ResumeSender: func() ResumeSender { return s.codeResumeSender },
		BeforeResumeIdentityCheck: func() {
			if s.codeResumeBeforeIdentityCheck != nil {
				s.codeResumeBeforeIdentityCheck()
			}
		},
		BeforeResumeFallbackAPNs: func() {
			if s.codeResumeFallbackBeforeAPNs != nil {
				s.codeResumeFallbackBeforeAPNs()
			}
		},
	})
	return s
}
func (s *testManager) Seed(ctx context.Context) { s.Manager.Seed(ctx, s.store) }
func (s *testManager) SetCodeAttestor(a apns.CodeIdentityAttestor) {
	s.SetAttestor(a)
	s.deps.Registry.(*registry.Registry).SetCodeAttestationConfigured(a != nil)
}

// No standalone worker belongs to this owner. Each challenge loop retains the
// context and terminal assertions supplied by its original fixture.
func (s *testManager) Close() {}
