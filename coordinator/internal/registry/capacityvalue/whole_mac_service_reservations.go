package capacityvalue

import (
	"math"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/google/uuid"
)

const MaxWholeMacServiceReservations = 64

// Validation is bounded and allocation-free on the admission path. A UUID is
// only an attempt identity; unknown IDs remain part of reported total usage.
func ValidWholeMacServiceReservations(capacity *protocol.BackendCapacity) bool {
	if len(capacity.WholeMacServiceReservations) > MaxWholeMacServiceReservations {
		return false
	}
	total := 0.0
	for i, reservation := range capacity.WholeMacServiceReservations {
		if len(reservation.ID) != 36 || uuid.Validate(reservation.ID) != nil ||
			math.IsNaN(reservation.UsedFraction) || math.IsInf(reservation.UsedFraction, 0) ||
			reservation.UsedFraction <= 0 || reservation.UsedFraction > 1 {
			return false
		}
		for j := 0; j < i; j++ {
			if strings.EqualFold(capacity.WholeMacServiceReservations[j].ID, reservation.ID) {
				return false
			}
		}
		total += reservation.UsedFraction
	}
	return capacity.WholeMacServiceUsed != nil && total <= *capacity.WholeMacServiceUsed+1e-12
}

// Detach and normalize accepted correlation metadata without retaining invalid
// provider-authored strings. Invalid modern reports fail closed at saturation;
// providers omitting the aggregate retain their existing legacy admission.
func cloneWholeMacServiceReservations(capacity, in *protocol.BackendCapacity) {
	capacity.WholeMacServiceReservations = nil
	if in.WholeMacServiceUsed == nil {
		return
	}
	total := *in.WholeMacServiceUsed
	if math.IsNaN(total) || math.IsInf(total, 0) || total < 0 || total > 1+1e-12 ||
		!ValidWholeMacServiceReservations(in) {
		saturated := 1.0
		capacity.WholeMacServiceUsed = &saturated
		return
	}
	if in.WholeMacServiceReservations != nil {
		capacity.WholeMacServiceReservations = make([]protocol.WholeMacServiceReservation, len(in.WholeMacServiceReservations))
		for i, reservation := range in.WholeMacServiceReservations {
			reservation.ID = strings.ToLower(reservation.ID)
			capacity.WholeMacServiceReservations[i] = reservation
		}
	}
}
