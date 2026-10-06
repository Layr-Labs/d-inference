package inference

import (
	"context"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/demand"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type autopilotDemandKey struct{}
type autopilotDemandRequest = demand.Request

func AutopilotDemandFromContext(ctx context.Context) *autopilotDemandRequest {
	if ctx == nil {
		return nil
	}
	d, _ := ctx.Value(autopilotDemandKey{}).(*autopilotDemandRequest)
	return d
}

func (s *Owner) BeginAutopilotDemand(r *http.Request, receivedAt time.Time) (*http.Request, *autopilotDemandRequest) {
	if s == nil || s.registry == nil || !observation.InferenceOutcomeEndpoint(r) || !s.registry.AutopilotEnabled() {
		return r, nil
	}
	d := demand.New(receivedAt)
	return r.WithContext(context.WithValue(r.Context(), autopilotDemandKey{}, d)), d
}

func armAutopilotDemand(r *http.Request, p AdmissionRequest) {
	traits := registry.RequestTraits{HasTools: p.HasTools}
	if p.Traits != nil {
		traits = *p.Traits
	}
	AutopilotDemandFromContext(r.Context()).Arm(demand.Admission{
		Model: p.Model, EstimatedPromptTokens: p.EstimatedPromptTokens, RequestedMaxTokens: p.RequestedMaxTokens,
		Deadline: p.Deadline, RequiresVision: p.RequiresVision, OwnerOnly: p.Policy.Enabled, PreferOwner: p.Policy.Prefer,
		AllowedProviderSerials: p.AllowedProviderSerials, Traits: traits, TraitsForModel: p.TraitsForModel,
	})
}

func setAutopilotDemandModel(r *http.Request, model string, traits registry.RequestTraits) {
	AutopilotDemandFromContext(r.Context()).SetModel(model, traits)
}

func BindAutopilotDemandProfile(r *http.Request, rp *registry.RequestProfile) {
	AutopilotDemandFromContext(r.Context()).BindProfile(rp)
}

func annotateAutopilotDemandRejection(info rejectionInfo) {
	if info.r == nil {
		return
	}
	AutopilotDemandFromContext(info.r.Context()).Annotate(demand.Rejection{
		ResolvedModel: info.resolvedModel, ReasonCode: info.reasonCode, HTTPStatus: info.httpStatus,
	})
}

func (s *Owner) FinishAutopilotDemand(r *http.Request, d *autopilotDemandRequest, status int) {
	if d == nil || s == nil || s.registry == nil {
		return
	}
	if sample, ok := d.Finish(status, r.Context().Err() != nil); ok {
		s.registry.RecordAutopilotDemand(sample)
	}
}
