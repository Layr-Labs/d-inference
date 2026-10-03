package inference

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

func markPublicModelDemand(r *http.Request, p inferenceAdmissionParams) {
	observation.MarkPublicModelDemand(r, p.policy.enabled, p.policy.prefer, p.allowedProviderSerials, p.publicModel, p.model)
}
