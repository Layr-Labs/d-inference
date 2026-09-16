// Package ingress owns consumer request preparation and admission before
// dispatch. HTTP middleware supplies identity and sealed-transport handling;
// the controller uses the same live routing, accounting and quota services.
package ingress

import (
	"context"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/accounts"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/inference/settlement"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Store is the persisted model, ownership and key-usage view used at admission.
type Store interface {
	GetModelRegistryRecord(string) (*store.ModelRegistryRecord, error)
	ListProvidersByAccount(context.Context, string) ([]store.ProviderRecord, error)
	KeySpendSince(string, time.Time) int64
}

// Metrics records the existing admission and request-policy counters.
type Metrics interface {
	Incr(string, []string)
	Count(string, int64, []string)
	Histogram(string, float64, []string)
}

// Observer connects preparation to request evidence owned by the HTTP layer.
// ParsedStream reports only the decoded mode; request content is not retained.
type Observer interface {
	NewProfile(*http.Request, string, string, bool) *registry.RequestProfile
	ParsedStream(context.Context, bool)
	DBCall(*registry.RequestProfile, time.Time)
	Rejection(dispatch.Rejection)
	RequestLocation(*http.Request) *store.ProviderLocation
	ExactCachePlan(registry.CachePlanResult)
}

// Dependencies resolves mutable configuration at its original read points.
// Registry, settlement, dispatch and quota handles are shared with completion;
// this controller does not create a second reservation, limiter or tracker.
type Dependencies struct {
	Registry                 func() *registry.Registry
	Store                    func() Store
	Logger                   func() *slog.Logger
	Dispatch                 func() *dispatch.Controller
	Settlement               func() settlement.Service
	BillingConfigured        func() bool
	FirstContentDeadlineBase func() time.Duration
	ServabilityGate          func() bool
	MediaResolver            func() *mediafetch.Resolver
	ConsumerTokens           func() *ratelimit.TokenLimiter
	ServiceTokens            func() *ratelimit.TokenLimiter
	KeyTokens                func() *ratelimit.KeyTokenLimiter
	OutputAdmissionEstimator func() *ratelimit.OutputAdmissionEstimator
	PromptArtifacts          func() *promptcontract.Provisioner
	PromptContract           func() *promptcontract.Client
	PromptPreloader          func() *promptcontract.PreloadController
	ModelShed                func(resolved, requested string) bool
	SealedRequest            func(*http.Request) bool
	Metrics                  Metrics
	Observer                 Observer
}

type Controller struct {
	deps             Dependencies
	tokenAdmissionMu [64]sync.Mutex // account-wide admission and output reconciliation
}

func New(deps Dependencies) *Controller {
	deps.Registry = optionalBinding(deps.Registry)
	deps.Store = optionalBinding(deps.Store)
	deps.Logger = optionalBinding(deps.Logger)
	deps.Dispatch = optionalBinding(deps.Dispatch)
	deps.Settlement = optionalBinding(deps.Settlement)
	deps.BillingConfigured = optionalBinding(deps.BillingConfigured)
	deps.FirstContentDeadlineBase = optionalBinding(deps.FirstContentDeadlineBase)
	deps.ServabilityGate = optionalBinding(deps.ServabilityGate)
	deps.MediaResolver = optionalBinding(deps.MediaResolver)
	deps.ConsumerTokens = optionalBinding(deps.ConsumerTokens)
	deps.ServiceTokens = optionalBinding(deps.ServiceTokens)
	deps.KeyTokens = optionalBinding(deps.KeyTokens)
	deps.OutputAdmissionEstimator = optionalBinding(deps.OutputAdmissionEstimator)
	deps.PromptArtifacts = optionalBinding(deps.PromptArtifacts)
	deps.PromptContract = optionalBinding(deps.PromptContract)
	deps.PromptPreloader = optionalBinding(deps.PromptPreloader)
	if deps.ModelShed == nil {
		deps.ModelShed = func(string, string) bool { return false }
	}
	if deps.SealedRequest == nil {
		deps.SealedRequest = func(*http.Request) bool { return false }
	}
	if deps.Metrics == nil {
		deps.Metrics = noMetrics{}
	}
	if deps.Observer == nil {
		deps.Observer = noObserver{}
	}
	return &Controller{deps: deps}
}

func optionalBinding[T any](get func() T) func() T {
	if get != nil {
		return get
	}
	return func() (zero T) { return }
}

func (s *Controller) checkKeySpendCap(ctx context.Context, additionalMicroUSD int64) (string, bool) {
	return accounts.CheckKeySpendCap(ctx, additionalMicroUSD, s.deps.Store())
}

type noMetrics struct{}

func (noMetrics) Incr(string, []string)               {}
func (noMetrics) Count(string, int64, []string)       {}
func (noMetrics) Histogram(string, float64, []string) {}

type noObserver struct{}

func (noObserver) NewProfile(*http.Request, string, string, bool) *registry.RequestProfile {
	return nil
}
func (noObserver) ParsedStream(context.Context, bool)                    {}
func (noObserver) DBCall(*registry.RequestProfile, time.Time)            {}
func (noObserver) Rejection(dispatch.Rejection)                          {}
func (noObserver) RequestLocation(*http.Request) *store.ProviderLocation { return nil }
func (noObserver) ExactCachePlan(registry.CachePlanResult)               {}
