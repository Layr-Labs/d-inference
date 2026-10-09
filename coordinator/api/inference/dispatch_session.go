package inference

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	providerdispatch "github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// DispatchRequest is the immutable admitted request handed off by either
// consumer endpoint. Retry, queue and speculative state are created privately.
type DispatchRequest struct {
	Writer                 http.ResponseWriter
	Request                *http.Request
	Model                  string
	PublicModel            string
	Body                   []byte
	ConsumerKey            string
	ConsumerLocation       *store.ProviderLocation
	ReservedMicroUSD       int64
	ServiceReservation     bool
	EstimatedPromptTokens  int
	RequestedMaxTokens     int
	TokenAdmission         registry.TokenAdmission
	RequiresVision         bool
	VisionImageCount       int
	Traits                 registry.RequestTraits
	IsResponsesAPI         bool
	ConsumerEndpoint       string
	RequestedStopSequences []string
	Stream                 bool
	MetadataDetails        bool
	Scope                  providerdispatch.Scope
	AllowedProviderSerials []string
	CachePlan              registry.CachePlan
	Timing                 *registry.RequestTiming
	Profile                *registry.RequestProfile
	Deadline               time.Duration
	FallbackDeadline       time.Duration
	PromptDeadlineForWork  func(string, *protocol.PromptWork) time.Duration
	SpeculativeAt          time.Duration
	ModelMaxContext        int
	RefundReservation      func()
}

func (s *Owner) NewDispatchSession(in DispatchRequest) *attempt.Session {
	d := &dispatchState{
		s: s, w: in.Writer, r: in.Request, model: in.Model, publicModel: in.PublicModel,
		rawBody: in.Body, consumerKey: in.ConsumerKey, consumerLocation: in.ConsumerLocation,
		reservedMicroUSD: in.ReservedMicroUSD, serviceReservation: in.ServiceReservation,
		estimatedPromptTokens: in.EstimatedPromptTokens, requestedMaxTokens: in.RequestedMaxTokens,
		tokenAdmission: in.TokenAdmission, requiresVision: in.RequiresVision, visionImageCount: in.VisionImageCount,
		hasTools: in.Traits.HasTools, requiresToolConstraint: in.Traits.RequiresToolConstraint,
		toolChoiceMode: in.Traits.ToolChoiceMode, toolChoiceName: in.Traits.ToolChoiceName,
		parallelToolCalls: in.Traits.ParallelToolCalls, isResponsesAPI: in.IsResponsesAPI,
		consumerEndpoint: in.ConsumerEndpoint, requestedStopSequences: in.RequestedStopSequences,
		stream: in.Stream, metadataDetails: in.MetadataDetails,
		policy:                 selfRoutePolicy{enabled: in.Scope.SelfRouteOnly, prefer: in.Scope.PreferOwner, ownerAccountID: in.Scope.OwnerAccountID},
		allowedProviderSerials: in.AllowedProviderSerials, cachePlan: in.CachePlan,
		timing: in.Timing, profile: in.Profile, deadline: in.Deadline, speculativeAt: in.SpeculativeAt,
		modelMaxContext: in.ModelMaxContext, refundReservation: in.RefundReservation,
		fallbackDeadline: in.FallbackDeadline, promptDeadlineForWork: in.PromptDeadlineForWork,
		excludeProviders: make(map[string]struct{}),
	}
	return d.newSession()
}

func (d *dispatchState) newSession() *attempt.Session {
	return attempt.NewSession(d.newAttemptLoop(), d.preflightLegacyCacheBust, d.finishDispatch, d.finalizeProfile)
}
