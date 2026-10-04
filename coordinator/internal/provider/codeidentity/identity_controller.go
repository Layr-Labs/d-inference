package codeidentity

import (
	"context"
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	codeidentity "github.com/eigeninference/d-inference/coordinator/internal/provider/identity"
	codecoverage "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/coverage"
	codepush "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/push"
	coderesume "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/resume"
	codereuse "github.com/eigeninference/d-inference/coordinator/internal/provider/identity/reuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Dependencies struct {
	Registry        *registry.Registry
	Store           store.Store
	Releases        *releases.Owner
	Observation     *observation.Owner
	Logger          *slog.Logger
	Throttle        *codeidentity.Throttle
	ResumeTransport coderesume.Transport
	ResumeRecovery  coderesume.Recovery
}

// codeIdentityController owns APNs proofs and live process-key resumption.
// It shares the injected throttle across the loop, reply and persistence paths.
type Controller struct {
	*coderesume.Manager
	*codereuse.Transition
	*codepush.Dispatcher
	*codecoverage.Observer
	registry           *registry.Registry
	store              store.Store
	releases           *releases.Owner
	observation        *observation.Owner
	logger             *slog.Logger
	codeAttestThrottle *codeidentity.Throttle
}

func New(d Dependencies) *Controller {
	s := &Controller{
		Dispatcher: codepush.New(d.Registry, d.Observation, d.Logger, d.Throttle),
		Observer:   codecoverage.New(d.Store, d.Observation, d.Logger, d.Throttle),
		registry:   d.Registry, store: d.Store, releases: d.Releases,
		observation: d.Observation, logger: d.Logger, codeAttestThrottle: d.Throttle,
	}
	recovery := d.ResumeRecovery
	if recovery == nil {
		recovery = s.RecoverResume
	}
	s.Manager = coderesume.New(d.Throttle, d.Logger, d.ResumeTransport, recovery)
	s.Transition = codereuse.New(d.Releases, d.Throttle, s.Manager, s.CodeAttestMetric, d.Logger)
	return s
}

func (s *Controller) RecoverResume(ctx context.Context, providerID string, provider *registry.Provider) {
	if ctx.Err() != nil {
		return // connection canceled after timer won; do not spend APNs budget
	}
	s.CodeAttestMetric("resume_timeout")
	s.codeAttestLoopWithResume(ctx, providerID, provider, false)
}
