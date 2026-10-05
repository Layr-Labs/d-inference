// Package serviceretirement owns the service charges that outlive a request.
// Its operations share the provider's existing serialization with admission,
// heartbeat processing and pending-request ownership.
package serviceretirement

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/deadline"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Ledger retains frozen identities and charges, never mutable retry owners.
// Only producer proof, a definitively unsent handoff, or disconnect releases a
// charge. Elapsed time and absence from a capacity report are not release proof.
type Ledger struct {
	shadows map[string]float64
}

// Account is the retirement contribution to an admission calculation.
type Account struct {
	Retiring         int
	UnreportedCharge float64
}

func (l *Ledger) Retain(id string, charge float64) {
	if id == "" {
		return
	}
	if l.shadows == nil {
		l.shadows = make(map[string]float64)
	}
	l.shadows[id] = charge
}

func (l *Ledger) Release(id string) bool {
	if l == nil {
		return false
	}
	_, released := l.shadows[id]
	delete(l.shadows, id)
	return released
}

func (l *Ledger) Reset() {
	if l != nil {
		l.shadows = nil
	}
}

func (l *Ledger) Account(reported []protocol.WholeMacServiceReservation) Account {
	if l == nil {
		return Account{}
	}
	a := Account{Retiring: len(l.shadows)}
	for id, charge := range l.shadows {
		a.UnreportedCharge += max(0, charge-ReportedCharge(reported, id))
	}
	return a
}

// Cover preserves the deadline builder's fail-closed treatment of retirement
// work that has not been attributed to the producer's reported service use.
func (l *Ledger) Cover(builder *deadline.WorkBuilder, reported []protocol.WholeMacServiceReservation) bool {
	if l != nil {
		for id, charge := range l.shadows {
			if !builder.Retiring(charge, ReportedCharge(reported, id)) {
				return false
			}
		}
	}
	return true
}

func ReportedCharge(reported []protocol.WholeMacServiceReservation, id string) float64 {
	for _, reservation := range reported {
		if reservation.ID == id {
			return reservation.UsedFraction
		}
	}
	return 0
}
