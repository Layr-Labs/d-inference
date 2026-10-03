package inference

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) HandleAdminModelTokenPromotions(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
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
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"promotions": promotions})
		return
	}
	var promotion store.ModelTokenPromotion
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&promotion); err != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "invalid promotion JSON"))
		return
	}
	if decoder.Decode(new(any)) != io.EOF {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "expected one JSON object"))
		return
	}
	if err := promotion.Validate(); err != nil {
		httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", err.Error()))
		return
	}
	if err := backend.PutModelTokenPromotion(promotion); err != nil {
		if errors.Is(err, store.ErrPromotionConflict) {
			httpx.WriteJSON(w, 409, httpx.ErrorResponse("promotion_conflict", "grant terms are immutable; only enabled can change"))
			return
		}
		s.writeServiceUnavailable(w, promotion.ModelID)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"ok": true, "model_id": promotion.ModelID})
}

func (s *Owner) HandleMyModelTokenPromotions(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	user := access.RequirePrivyUser(w, r)
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
		httpx.WriteJSON(w, 200, map[string]any{"grants": []store.ModelTokenGrant{}, "offers": []store.ModelTokenOffer{}})
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
			httpx.WriteJSON(w, 400, httpx.ErrorResponse("invalid_request_error", "model_id is required"))
			return
		}
		grants, err = backend.ClaimModelTokenPromotion(user.AccountID, input.ModelID, now)
	} else {
		grants, err = backend.ListModelTokenGrants(user.AccountID)
	}
	if err != nil {
		switch {
		case errors.Is(err, store.ErrPromotionIneligible):
			httpx.WriteJSON(w, 403, httpx.ErrorResponse("promotion_ineligible", "Your account was created after this promotion's signup cutoff.", httpx.WithCode("promotion_ineligible")))
		case errors.Is(err, store.ErrPromotionFull):
			httpx.WriteJSON(w, 409, httpx.ErrorResponse("promotion_sold_out", "All grants for this promotion have been claimed.", httpx.WithCode("promotion_sold_out")))
		case errors.Is(err, store.ErrPromotionUnavailable):
			httpx.WriteJSON(w, 409, httpx.ErrorResponse("promotion_unavailable", "This promotion is not open for claims.", httpx.WithCode("promotion_unavailable")))
		case errors.Is(err, store.ErrNotFound):
			httpx.WriteJSON(w, 404, httpx.ErrorResponse("promotion_not_found", "This promotion does not exist.", httpx.WithCode("promotion_not_found")))
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
	httpx.WriteJSON(w, 200, map[string]any{"grants": grants, "offers": offers})
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

func (s *Owner) releaseModelTokenRequest(r *http.Request) bool {
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

func (s *Owner) releaseModelTokenReservation(id string) (bool, error) {
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
