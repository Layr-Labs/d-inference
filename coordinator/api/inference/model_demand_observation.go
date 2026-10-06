package inference

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
)

func markPublicModelDemand(r *http.Request, p AdmissionRequest) {
	observation.MarkPublicModelDemand(r, p.Policy.Enabled, p.Policy.Prefer, p.AllowedProviderSerials, p.PublicModel, p.Model)
}
