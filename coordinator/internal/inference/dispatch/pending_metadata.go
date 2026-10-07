package dispatch

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/promotions"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type PendingMetadata struct {
	Endpoint      string
	StopSequences []string
	Details       bool
}

func ConfigurePending(pr *registry.PendingRequest, r *http.Request, metadata PendingMetadata) {
	if pr == nil {
		return
	}
	promotions.StampReservation(pr, promotions.Reservation(r))
	pr.ConsumerEndpoint = metadata.Endpoint
	pr.RequestedStopSequences = append(pr.RequestedStopSequences[:0], metadata.StopSequences...)
	pr.MetadataDetails = metadata.Details
}
