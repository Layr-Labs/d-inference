// Package service owns App Attest exchanges, evidence retention, receipt
// renewal, machine inventory, and serving authorization. HTTP authentication
// and the generic signed-release catalog remain in the API adapter.
package service

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ReleasePolicy captures one immutable catalog generation. Approves must close
// over that same snapshot rather than reload a newer generation mid-decision.
type ReleasePolicy struct {
	Generation               uint64
	Known                    bool
	Approves                 func(*registry.Provider, *protocol.AppAttestStatus) bool
	ContainsQualifiedRelease func(store.Release) bool
}

type Dependencies struct {
	Store                store.Store
	Registry             *registry.Registry
	Logger               *slog.Logger
	Metrics              Metrics
	Emit                 func(map[string]any)
	SendTrustStatus      func(*registry.Provider, registry.TrustLevel, string, string)
	CurrentReleasePolicy func() ReleasePolicy
	RefreshReleasePolicy func() error
}

type Service struct {
	store                store.Store
	registry             *registry.Registry
	logger               *slog.Logger
	config               Config
	lifetime             context.Context
	authorizer           *authorizer
	verifierSlots        chan struct{}
	storageOnce          sync.Once
	storageSlots         chan struct{}
	inventorySlots       chan struct{}
	startOnce            sync.Once
	metrics              Metrics
	emitEvent            func(map[string]any)
	trustStatus          func(*registry.Provider, registry.TrustLevel, string, string)
	currentReleasePolicy func() ReleasePolicy
	refreshReleasePolicy func() error
	qualificationMu      sync.Mutex
	qualifications       atomic.Pointer[buildQualificationSnapshot]
}

// New constructs the service without starting workers, which also allows unit
// tests to exercise deterministic exchanges without background goroutines.
func New(ctx context.Context, cfg Config, deps Dependencies) *Service {
	if ctx == nil {
		ctx = context.Background()
	}
	logger := deps.Logger
	if logger == nil {
		logger = slog.Default()
	}
	return &Service{
		store: deps.Store, registry: deps.Registry, logger: logger,
		config: cfg, lifetime: ctx,
		verifierSlots: make(chan struct{}, 4), inventorySlots: make(chan struct{}, 4),
		metrics: deps.Metrics, emitEvent: deps.Emit, trustStatus: deps.SendTrustStatus,
		currentReleasePolicy: deps.CurrentReleasePolicy,
		refreshReleasePolicy: deps.RefreshReleasePolicy,
	}
}

// Start owns workers until the constructor's context is cancelled. Receipt
// maintenance and inventory remain active even when shadow verification is off.
func (s *Service) Start() {
	s.startOnce.Do(func() {
		if s.config.Enabled || s.config.ServingEnabled {
			s.startBuildQualifications(s.lifetime)
		}
		s.startAppAttestReceiptWorker(s.lifetime)
		s.startAppAttestMaintenance(s.lifetime)
		s.startAppAttestAuthorizer(s.lifetime)
		s.startMachineInventoryBackfill(s.lifetime)
		s.startMachineInventoryReconciler(s.lifetime)
	})
}

func (s *Service) StartSession(ctx context.Context, p *registry.Provider, r *protocol.RegisterMessage, account string) *Session {
	return s.startAppAttestShadow(ctx, p, r, account)
}

func (x *Session) Offer(p protocol.AppAttestShadowPayload) { x.offer(p) }

// RejectOversized preserves evidence-gap accounting for frames rejected by the
// HTTP/WebSocket reader before the bounded feature inbox can decode them.
func (x *Session) RejectOversized() { x.markDropped() }

func (s *Service) Status(p *registry.Provider) *protocol.ProviderServingAuthorization {
	return s.providerServingAuthorizationStatus(p)
}

// IdentityCandidate accepts only the API's validated token account, never an
// account string supplied in registration hardware/status fields.
func (s *Service) IdentityCandidate(r *protocol.RegisterMessage, account string) bool {
	return s.appAttestIdentityCandidate(r, account)
}

func (s *Service) currentReleasePolicySnapshot() *ReleasePolicy {
	if s.currentReleasePolicy == nil {
		return nil
	}
	p := s.currentReleasePolicy()
	return &p
}

func appAttestReleaseApproved(snapshot *ReleasePolicy, p *registry.Provider, status *protocol.AppAttestStatus) bool {
	return snapshot != nil && snapshot.Known && snapshot.Approves != nil && snapshot.Approves(p, status)
}

func (s *Service) sendTrustStatus(p *registry.Provider, level registry.TrustLevel, status, reason string) {
	if s.trustStatus != nil {
		s.trustStatus(p, level, status, reason)
	}
}
