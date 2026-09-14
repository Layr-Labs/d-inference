package dispatch

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// RoutePolicy carries the authenticated "use my own machine, for free"
// decision through dispatch so that primary, sequential-retry, and
// speculative-backup PendingRequests all inherit the same owner filter and
// free-billing flag. It is resolved entirely server-side (from the request's
// authenticated identity plus the X-Darkbloom-Route header / per-key flag);
// no field originates from the request body.
type RoutePolicy struct {
	// Enabled is EXCLUSIVE self-route: restrict routing to providers owned by
	// OwnerAccountID, mark the request free, and never fall back to the paid
	// fleet. The zero value is a normal paid request to any provider.
	Enabled bool
	// Prefer is "prefer my own machine, fall back to the paid fleet": route to
	// an owned provider whenever one can serve (free), otherwise use the public
	// fleet (charged). Mutually exclusive with `Enabled`; it takes a normal
	// reservation up front so the paid fallback can settle, and billing is
	// decided at settlement by whether an owned machine actually served it.
	Prefer bool
	// OwnerAccountID is the account that must own the serving provider.
	OwnerAccountID string
}

// Request contains the validated input and shared lifecycle objects for one dispatch.
// Run creates its private mutable attempt state without copying those objects.
type Request struct {
	Model                  string
	PublicModel            string
	RawBody                []byte
	ConsumerKey            string
	ConsumerLocation       *store.ProviderLocation
	ReservedMicroUSD       int64
	TokenAdmission         registry.TokenAdmission
	ServiceReservation     bool
	EstimatedPromptTokens  int
	RequestedMaxTokens     int
	RequiresVision         bool
	VisionImageCount       int
	HasTools               bool
	RequiresToolConstraint bool
	ToolChoiceMode         string
	ToolChoiceName         string
	ParallelToolCalls      bool
	IsResponsesAPI         bool
	Stream                 bool
	MetadataDetails        bool
	Policy                 RoutePolicy
	AllowedProviderSerials []string
	CachePlan              registry.CachePlan
	Timing                 *registry.RequestTiming
	Profile                *registry.RequestProfile
	Deadline               time.Duration
	SpeculativeAt          time.Duration
	ModelMaxContext        int
	RefundReservation      func()
	ConsumerEndpoint       string
	RequestedStopSequences []string
}

// Run selects and commits a provider, then writes the response through the shared writer.
func (s *Controller) Run(w http.ResponseWriter, r *http.Request, request Request) {
	d := &execution{
		s: s, w: w, r: r,
		model:                  request.Model,
		publicModel:            request.PublicModel,
		rawBody:                request.RawBody,
		consumerKey:            request.ConsumerKey,
		consumerLocation:       request.ConsumerLocation,
		reservedMicroUSD:       request.ReservedMicroUSD,
		tokenAdmission:         request.TokenAdmission,
		serviceReservation:     request.ServiceReservation,
		estimatedPromptTokens:  request.EstimatedPromptTokens,
		requestedMaxTokens:     request.RequestedMaxTokens,
		requiresVision:         request.RequiresVision,
		visionImageCount:       request.VisionImageCount,
		hasTools:               request.HasTools,
		requiresToolConstraint: request.RequiresToolConstraint,
		toolChoiceMode:         request.ToolChoiceMode,
		toolChoiceName:         request.ToolChoiceName,
		parallelToolCalls:      request.ParallelToolCalls,
		isResponsesAPI:         request.IsResponsesAPI,
		stream:                 request.Stream,
		metadataDetails:        request.MetadataDetails,
		policy:                 request.Policy,
		allowedProviderSerials: request.AllowedProviderSerials,
		cachePlan:              request.CachePlan,
		timing:                 request.Timing,
		profile:                request.Profile,
		deadline:               request.Deadline,
		speculativeAt:          request.SpeculativeAt,
		modelMaxContext:        request.ModelMaxContext,
		refundReservation:      request.RefundReservation,
		consumerEndpoint:       request.ConsumerEndpoint,
		requestedStopSequences: request.RequestedStopSequences,
		excludeProviders:       make(map[string]struct{}),
	}
	d.run()
}
