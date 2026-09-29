package registry

import (
	"crypto/rand"
	"math"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/google/uuid"
)

const maxWholeMacServiceReservations = 64

// Keep entropy and the immutable wire value in one owned object: random reads
// need escaping storage, and admission repeatedly reads the already-formatted
// UUID without allocating. The pointer publication is atomic across retries.
type serviceReservationIdentity struct {
	entropy uuid.UUID
	wire    string
}

func newServiceReservationIdentity() *serviceReservationIdentity {
	id := new(serviceReservationIdentity)
	if _, err := rand.Read(id.entropy[:]); err != nil {
		panic(err)
	}
	id.entropy[6] = (id.entropy[6] & 0x0f) | 0x40 // RFC 4122 version 4
	id.entropy[8] = (id.entropy[8] & 0x3f) | 0x80 // RFC 4122 variant
	id.wire = id.entropy.String()
	return id
}

// Validation is bounded and allocation-free on the admission path. A UUID is
// only an attempt identity; unknown IDs remain part of reported total usage.
func validWholeMacServiceReservations(capacity *protocol.BackendCapacity) bool {
	if len(capacity.WholeMacServiceReservations) > maxWholeMacServiceReservations {
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
		!validWholeMacServiceReservations(in) {
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
