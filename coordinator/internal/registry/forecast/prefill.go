package forecast

import "time"

type PrefillReservation struct {
	Known     bool
	Tokens    float64
	RestoreMS float64
}

func ReservePrefill(estimate Estimate) PrefillReservation {
	return PrefillReservation{Known: estimate.PromptTokens > 0,
		Tokens: max(0, float64(estimate.PromptTokens)-estimate.CachedTokens), RestoreMS: estimate.RestoreMs}
}

// PrefillQueue reconciles local work against the latest accepted capacity frame.
// Earlier reservations may overlap that frame; newer reservations cannot.
type PrefillQueue struct {
	unreportedTokens   float64
	unreportedUnknown  int
	overlappingTokens  float64
	overlappingUnknown int
}

type PendingPrefill struct {
	Reservation                                       PrefillReservation
	EstimatedPromptTokens                             int
	CacheParticipates, ContentCommitted, ModelMatches bool
	ReservedAt                                        time.Time
}

func (q *PrefillQueue) Add(pending PendingPrefill, acceptedAt time.Time) float64 {
	if !pending.ModelMatches || pending.ContentCommitted {
		return 0
	}
	tokens, known := pending.Reservation.Tokens, pending.Reservation.Known
	if !known && pending.EstimatedPromptTokens > 0 && !pending.CacheParticipates {
		tokens, known = float64(pending.EstimatedPromptTokens), true
	}
	unreported := !acceptedAt.IsZero() && !pending.ReservedAt.Before(acceptedAt)
	if unreported {
		if known {
			q.unreportedTokens += tokens
		} else {
			q.unreportedUnknown++
		}
	} else {
		if known {
			q.overlappingTokens += tokens
		} else {
			q.overlappingUnknown++
		}
	}
	return pending.Reservation.RestoreMS
}

func (q PrefillQueue) Ahead(queuedTokens int64, queuedKnown bool, waiting, prompt int) float64 {
	localOverlap := q.overlappingTokens + float64(q.overlappingUnknown)*float64(max(0, prompt))
	reported := float64(waiting) * float64(max(0, prompt))
	if queuedKnown {
		reported = float64(queuedTokens)
	}
	return max(localOverlap, reported) + q.unreportedTokens + float64(q.unreportedUnknown)*float64(max(0, prompt))
}
