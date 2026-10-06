package registry

import (
	"crypto/rand"

	"github.com/google/uuid"
)

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
