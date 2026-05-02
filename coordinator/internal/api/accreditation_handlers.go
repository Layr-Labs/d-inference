package api

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/eigeninference/coordinator/internal/registry"
)

type accreditationEnrollRequest struct {
	ProviderID   string `json:"provider_id"`
	EnrollmentID string `json:"enrollment_id"`
}

type accreditationPaymentConfirmRequest struct {
	ProviderID string `json:"provider_id"`
	PaymentID  string `json:"payment_id"`
}

type accreditationVerifyRequest struct {
	ProviderID string `json:"provider_id"`
}

type accreditationRevokeRequest struct {
	ProviderID string `json:"provider_id"`
	Reason     string `json:"reason,omitempty"`
}

type accreditationStatusResponse struct {
	ProviderID          string  `json:"provider_id"`
	Accreditation       string  `json:"accreditation"`
	Payment             string  `json:"payment"`
	EnrollmentID        string  `json:"enrollment_id,omitempty"`
	PaymentID           string  `json:"payment_id,omitempty"`
	VerifiedAt          *string `json:"verified_at,omitempty"`
	RevokedAt           *string `json:"revoked_at,omitempty"`
	EligibleForPaidWork bool    `json:"eligible_for_paid_work"`
}

func (s *Server) handleAccreditationEnroll(w http.ResponseWriter, r *http.Request) {
	var req accreditationEnrollRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.ProviderID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "provider_id is required"))
		return
	}
	if req.EnrollmentID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "enrollment_id is required"))
		return
	}

	p := s.registry.GetProvider(req.ProviderID)
	if p == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "provider not found"))
		return
	}

	if err := p.SetAccreditation(registry.AccreditationPendingPayment, registry.PaymentPending, req.EnrollmentID, ""); err != nil {
		writeJSON(w, http.StatusConflict, errorResponse("conflict", err.Error()))
		return
	}

	s.logger.Info("provider enrolled for accreditation",
		"provider_id", req.ProviderID,
		"enrollment_id", req.EnrollmentID,
	)

	writeJSON(w, http.StatusOK, accreditationStatusFromProvider(p))
}

func (s *Server) handleAccreditationPaymentConfirm(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}

	var req accreditationPaymentConfirmRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.ProviderID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "provider_id is required"))
		return
	}
	if req.PaymentID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "payment_id is required"))
		return
	}

	p := s.registry.GetProvider(req.ProviderID)
	if p == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "provider not found"))
		return
	}

	if err := p.SetAccreditation(registry.AccreditationPendingReview, registry.PaymentConfirmed, "", req.PaymentID); err != nil {
		writeJSON(w, http.StatusConflict, errorResponse("conflict", err.Error()))
		return
	}

	s.logger.Info("accreditation payment confirmed",
		"provider_id", req.ProviderID,
		"payment_id", req.PaymentID,
	)

	writeJSON(w, http.StatusOK, accreditationStatusFromProvider(p))
}

func (s *Server) handleAccreditationPaymentFail(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}

	var req accreditationPaymentConfirmRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.ProviderID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "provider_id is required"))
		return
	}

	p := s.registry.GetProvider(req.ProviderID)
	if p == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "provider not found"))
		return
	}

	if err := p.SetAccreditation(registry.AccreditationPaymentFailed, registry.PaymentFailed, "", req.PaymentID); err != nil {
		writeJSON(w, http.StatusConflict, errorResponse("conflict", err.Error()))
		return
	}

	s.logger.Info("accreditation payment failed",
		"provider_id", req.ProviderID,
		"payment_id", req.PaymentID,
	)

	writeJSON(w, http.StatusOK, accreditationStatusFromProvider(p))
}

func (s *Server) handleAccreditationVerify(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}

	var req accreditationVerifyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.ProviderID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "provider_id is required"))
		return
	}

	p := s.registry.GetProvider(req.ProviderID)
	if p == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "provider not found"))
		return
	}

	if err := p.SetAccreditation(registry.AccreditationActive, registry.PaymentConfirmed, "", ""); err != nil {
		writeJSON(w, http.StatusConflict, errorResponse("conflict", err.Error()))
		return
	}

	s.logger.Info("provider accredited",
		"provider_id", req.ProviderID,
	)

	writeJSON(w, http.StatusOK, accreditationStatusFromProvider(p))
}

func (s *Server) handleAccreditationRevoke(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}

	var req accreditationRevokeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.ProviderID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "provider_id is required"))
		return
	}

	p := s.registry.GetProvider(req.ProviderID)
	if p == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "provider not found"))
		return
	}

	if err := p.SetAccreditation(registry.AccreditationRevoked, registry.PaymentConfirmed, "", ""); err != nil {
		writeJSON(w, http.StatusConflict, errorResponse("conflict", err.Error()))
		return
	}

	s.logger.Info("provider accreditation revoked",
		"provider_id", req.ProviderID,
		"reason", req.Reason,
	)

	writeJSON(w, http.StatusOK, accreditationStatusFromProvider(p))
}

func (s *Server) handleAccreditationStatus(w http.ResponseWriter, r *http.Request) {
	providerID := r.URL.Query().Get("provider_id")
	if providerID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "provider_id query parameter is required"))
		return
	}

	p := s.registry.GetProvider(providerID)
	if p == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "provider not found"))
		return
	}

	writeJSON(w, http.StatusOK, accreditationStatusFromProvider(p))
}

func accreditationStatusFromProvider(p *registry.Provider) accreditationStatusResponse {
	resp := accreditationStatusResponse{
		ProviderID:          p.ID,
		Accreditation:       string(p.Accreditation),
		Payment:             string(p.AccreditationPayment),
		EnrollmentID:        p.AccreditationEnrollmentID,
		PaymentID:           p.AccreditationPaymentID,
		EligibleForPaidWork: p.IsEligibleForPaidWork(),
	}
	if p.AccreditationVerifiedAt != nil {
		s := p.AccreditationVerifiedAt.Format(time.RFC3339)
		resp.VerifiedAt = &s
	}
	if p.AccreditationRevokedAt != nil {
		s := p.AccreditationRevokedAt.Format(time.RFC3339)
		resp.RevokedAt = &s
	}
	return resp
}
