package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) handleAdminModelTokenPromotions(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		s.writeServiceUnavailable(w, "")
		return
	}
	if r.Method == http.MethodGet {
		promotions, err := backend.ListModelTokenPromotions()
		if err != nil {
			s.writeServiceUnavailable(w, "")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"promotions": promotions})
		return
	}
	var promotion store.ModelTokenPromotion
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&promotion); err != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", "invalid promotion JSON"))
		return
	}
	if decoder.Decode(new(any)) != io.EOF {
		writeJSON(w, 400, errorResponse("invalid_request_error", "expected one JSON object"))
		return
	}
	if err := promotion.Validate(); err != nil {
		writeJSON(w, 400, errorResponse("invalid_request_error", err.Error()))
		return
	}
	if err := backend.PutModelTokenPromotion(promotion); err != nil {
		if errors.Is(err, store.ErrPromotionConflict) {
			writeJSON(w, 409, errorResponse("promotion_conflict", "grant terms are immutable; only enabled can change"))
			return
		}
		s.writeServiceUnavailable(w, promotion.ModelID)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "model_id": promotion.ModelID})
}

func (s *Server) handleMyModelTokenPromotions(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	// The initial Privy provisioning result need not contain database defaults.
	// Eligibility always uses the coordinator's persisted account creation time.
	persisted, err := s.store.GetUserByAccountID(user.AccountID)
	if err != nil {
		s.writeServiceUnavailable(w, "")
		return
	}
	user = persisted
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		s.writeServiceUnavailable(w, "")
		return
	}
	if user.Role == store.RoleService {
		writeJSON(w, 200, map[string]any{"grants": []store.ModelTokenGrant{}, "offers": []store.ModelTokenOffer{}})
		return
	}
	var grants []store.ModelTokenGrant
	now := time.Now()
	if r.Method == http.MethodPost {
		var input struct {
			ModelID string `json:"model_id"`
		}
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&input) != nil || input.ModelID == "" || decoder.Decode(new(any)) != io.EOF {
			writeJSON(w, 400, errorResponse("invalid_request_error", "model_id is required"))
			return
		}
		grants, err = backend.ClaimModelTokenPromotion(user.AccountID, input.ModelID, now)
	} else {
		grants, err = backend.ListModelTokenGrants(user.AccountID)
	}
	if err != nil {
		switch {
		case errors.Is(err, store.ErrPromotionIneligible):
			writeJSON(w, 403, errorResponse("promotion_ineligible", "Your account was created after this promotion's signup cutoff.", withCode("promotion_ineligible")))
		case errors.Is(err, store.ErrPromotionFull):
			writeJSON(w, 409, errorResponse("promotion_sold_out", "All grants for this promotion have been claimed.", withCode("promotion_sold_out")))
		case errors.Is(err, store.ErrPromotionUnavailable):
			writeJSON(w, 409, errorResponse("promotion_unavailable", "This promotion is not open for claims.", withCode("promotion_unavailable")))
		case errors.Is(err, store.ErrNotFound):
			writeJSON(w, 404, errorResponse("promotion_not_found", "This promotion does not exist.", withCode("promotion_not_found")))
		default:
			s.writeServiceUnavailable(w, "")
		}
		return
	}
	promotions, err := backend.ListModelTokenPromotions()
	if err != nil {
		s.writeServiceUnavailable(w, "")
		return
	}
	claimed := make(map[string]bool, len(grants))
	for _, grant := range grants {
		claimed[grant.ModelID] = true
	}
	offers := make([]store.ModelTokenOffer, 0, len(promotions))
	for _, promotion := range promotions {
		offers = append(offers, promotion.Offer(user, now, claimed[promotion.ModelID]))
	}
	writeJSON(w, 200, map[string]any{"grants": grants, "offers": offers})
}

type modelTokenRequestKey struct{}
type modelTokenRequestState struct{ reservation *store.ModelTokenReservation }

func withModelTokenRequest(r *http.Request) *http.Request {
	return r.WithContext(context.WithValue(r.Context(), modelTokenRequestKey{}, &modelTokenRequestState{}))
}

func modelTokenRequest(r *http.Request) *modelTokenRequestState {
	if r == nil {
		return nil
	}
	state, _ := r.Context().Value(modelTokenRequestKey{}).(*modelTokenRequestState)
	return state
}

func modelTokenReservation(r *http.Request) *store.ModelTokenReservation {
	if state := modelTokenRequest(r); state != nil {
		return state.reservation
	}
	return nil
}

func (s *Server) releaseModelTokenRequest(r *http.Request) bool {
	reservation := modelTokenReservation(r)
	if reservation == nil {
		return false
	}
	_, err := s.releaseModelTokenReservation(reservation.ID)
	if err != nil {
		s.logger.Error("promotion reservation refund failed", "reservation_id", reservation.ID, "error", err)
	}
	return true
}

func (s *Server) releaseModelTokenReservation(id string) (bool, error) {
	if _, pending := s.modelTokenSettlements.Load(id); pending {
		return false, nil
	}
	backend, ok := store.As[store.ModelTokenPromotionStore](s.store)
	if !ok {
		return false, errors.New("promotion store unavailable")
	}
	released, err := backend.ReleaseModelTokenReservation(id)
	if err == nil {
		s.modelTokenActive.Delete(id)
		s.modelTokenRefunds.Delete(id)
	} else {
		s.modelTokenRefunds.Store(id, struct{}{})
	}
	return released, err
}
