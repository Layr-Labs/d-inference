package dispatch

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Input carries one attempt's immutable inputs to the common dispatch funnel.
// Forecast and Exclusions belong to the logical request, including its hedge.
type Input struct {
	Request                *http.Request
	Model                  string
	PublicModel            string
	Body                   []byte
	ConsumerKey            string
	ConsumerLocation       *store.ProviderLocation
	ReservedMicroUSD       int64
	EstimatedPromptTokens  int
	Deadline               time.Duration
	RequestedMaxTokens     int
	TokenAdmission         registry.TokenAdmission
	RequiresVision         bool
	Traits                 registry.RequestTraits
	AllowedProviderSerials []string
	IsResponsesAPI         bool
	Scope                  Scope
	Timing                 *registry.RequestTiming
	ServiceReservation     bool
	CachePlan              registry.CachePlan
	Exclusions             Exclusions
	Attempt                int
	Profile                *registry.RequestProfile
	BackupOf               string
	RecordRoute            RouteRecorder
	OnDispatched           func()
	Forecast               *firstcontent.Forecast
}

type Result struct {
	Provider  *registry.Provider
	Pending   *registry.PendingRequest
	Decision  registry.RoutingDecision
	Plan      *registry.DispatchPlan
	Error     string
	ErrorCode int
}

// PlanSelection distinguishes a reservation (even if its write failed) from
// the exhausted/unavailable cases that must fall back to ordinary selection.
type PlanSelection uint8

const (
	PlanUnavailable PlanSelection = iota
	PlanRetained
	PlanRefreshed
	PlanRefreshEmpty
	PlanExhausted
)

func (s PlanSelection) Tried() bool { return s == PlanRetained || s == PlanRefreshed }

// Plan owns the first retained plan and the request-wide refresh/probe budgets.
// Selection runs on the request goroutine; only the registry plan and probe
// result channels are shared with the quote collector.
type Plan struct {
	dispatcher      *Dispatcher
	plan            *registry.DispatchPlan
	refreshUsed     bool
	probesLaunched  bool
	probeDone       <-chan struct{}
	freshQuotesUsed bool
}

func (s *Dispatcher) NewPlan(initial *registry.DispatchPlan) *Plan {
	return &Plan{dispatcher: s, plan: initial}
}

func (p *Plan) Dispatch(in Input, reserve Reserver, fullScan bool) (out Result) {
	out.Provider, out.Pending, out.Decision, out.Plan, out.Error, out.ErrorCode = p.dispatcher.Dispatch(
		in.Request, in.Model, in.PublicModel, in.Body, in.ConsumerKey, in.ConsumerLocation,
		in.ReservedMicroUSD, in.EstimatedPromptTokens, in.Deadline, in.RequestedMaxTokens,
		in.TokenAdmission, in.RequiresVision, in.Traits, in.AllowedProviderSerials,
		in.IsResponsesAPI, in.Scope, in.Timing, in.ServiceReservation, in.CachePlan,
		in.Exclusions, in.Attempt, in.Profile, in.BackupOf, in.RecordRoute, in.OnDispatched, fullScan,
		func(pr *registry.PendingRequest, ids []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
			in.Forecast.Configure(pr, in.Model, in.EstimatedPromptTokens, in.Deadline, in.BackupOf != "")
			return reserve(pr, ids)
		},
	)
	return out
}

func (p *Plan) Scan(in Input) Result {
	out := p.Dispatch(in, p.dispatcher.ScanReserver(in.Model), true)
	// Never replace an exhausted chain with a later fallback scan.
	if p.plan == nil {
		p.plan = out.Plan
	}
	return out
}

// Next consumes bounded, currently revalidated entries before spending the
// single full-scan refresh shared by retry and speculative dispatch.
func (p *Plan) Next(in Input) (Result, PlanSelection) {
	plan := p.plan
	if plan == nil {
		return Result{}, PlanUnavailable
	}
	reserved := false
	out := p.Dispatch(in, func(pr *registry.PendingRequest, ids []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
		provider, decision, _ := p.dispatcher.registry.ReserveNextFromPlan(pr, plan, ids...)
		reserved = provider != nil
		return provider, decision, nil
	}, false)
	if reserved {
		return out, PlanRetained
	}
	if p.refreshUsed {
		return Result{Decision: out.Decision}, PlanExhausted
	}
	p.refreshUsed = true
	out = p.Dispatch(in, func(pr *registry.PendingRequest, ids []string) (*registry.Provider, registry.RoutingDecision, *registry.DispatchPlan) {
		provider, decision, fresh, performed := p.dispatcher.registry.RefreshDispatchPlan(pr, plan, ids...)
		if !performed {
			return nil, decision, nil
		}
		reserved = provider != nil
		return provider, decision, fresh
	}, true)
	if out.Plan != nil {
		p.plan = out.Plan
	}
	if !reserved {
		return Result{Decision: out.Decision}, PlanRefreshEmpty
	}
	return out, PlanRefreshed
}
