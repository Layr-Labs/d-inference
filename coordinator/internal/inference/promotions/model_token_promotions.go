package promotions

import (
	"context"
	"errors"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type modelTokenRequestKey struct{}

type modelTokenRequestState struct{ reservation *store.ModelTokenReservation }

func WithRequest(r *http.Request) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), modelTokenRequestKey{}, &modelTokenRequestState{}))
}

func modelTokenRequest(r *http.Request) *modelTokenRequestState {
	if r == nil {
		return nil
	}
	state, _ := r.Context().Value(modelTokenRequestKey{}).(*modelTokenRequestState)
	return state
}

func Reservation(r *http.Request) *store.ModelTokenReservation {
	if state := modelTokenRequest(r); state != nil {
		return state.reservation
	}
	return nil
}

func (s *Engine) ReleaseRequest(r *http.Request) bool {
	reservation := Reservation(r)
	if reservation == nil {
		return false
	}
	_, err := s.Release(reservation.ID)
	if err != nil {
		s.logger.Error("promotion reservation refund failed", "reservation_id", reservation.ID, "error", err)
	}
	return true
}

func (s *Engine) Release(id string) (bool, error) {
	if _, pending := s.settlements.Load(id); pending {
		return false, nil
	}
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		return false, errors.New("promotion store unavailable")
	}
	released, err := backend.ReleaseModelTokenReservation(id)
	if err == nil {
		s.active.Delete(id)
		s.refunds.Delete(id)
	} else {
		s.refunds.Store(id, struct{}{})
	}
	return released, err
}
