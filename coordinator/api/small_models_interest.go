package api

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/mail"
	"strconv"
	"strings"
	"unicode"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) handleRegisterSmallModelsInterest(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	// requirePrivyAuth supplies this account; the request cannot choose its owner.
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "interactive session required"))
		return
	}
	address, err := mail.ParseAddress(user.Email)
	if err != nil || address.Address != user.Email {
		writeJSON(w, http.StatusUnprocessableEntity, errorResponse("email_required", "an account email address is required"))
		return
	}
	var input struct {
		MacType string `json:"mac_type"`
		Chip    string `json:"chip"`
		RAMGB   int    `json:"ram_gb"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 1024)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		interestJSONError(w, err)
		return
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		interestJSONError(w, err)
		return
	}
	validMac := input.MacType == "MacBook Pro" || input.MacType == "Mac Mini" || input.MacType == "Mac Studio" || input.MacType == "Mac Pro"
	if !validMac || strings.TrimSpace(input.Chip) == "" || len(input.Chip) > 128 ||
		strings.IndexFunc(input.Chip, unicode.IsControl) >= 0 || input.RAMGB < 1 || input.RAMGB > 2048 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "valid Mac type, chip (1–128 bytes), and integer ram_gb (1–2048) are required"))
		return
	}
	err = s.store.UpsertSmallModelsInterest(r.Context(), store.SmallModelsInterest{
		AccountID: user.AccountID, MacType: input.MacType, Chip: input.Chip, RAMGB: input.RAMGB,
	})
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("storage_error", "could not save interest"))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func interestJSONError(w http.ResponseWriter, err error) {
	status := http.StatusBadRequest
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		status = http.StatusRequestEntityTooLarge
	}
	writeJSON(w, status, errorResponse("invalid_request_error", "body must be one JSON object with only mac_type, chip, and ram_gb (maximum 1024 bytes)"))
}

func (s *Server) handleGetSmallModelsInterest(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("authentication_error", "interactive session required"))
		return
	}
	record, err := s.store.GetSmallModelsInterest(r.Context(), user.AccountID)
	if errors.Is(err, store.ErrNotFound) {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "interest not registered"))
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("storage_error", "could not read interest"))
		return
	}
	w.Header().Set("Cache-Control", "private, no-store")
	writeJSON(w, http.StatusOK, record)
}

func (s *Server) handleAdminSmallModelsInterest(w http.ResponseWriter, r *http.Request) {
	if r.Context().Value(ctxKeyAPIKey) != nil {
		writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin key or interactive admin session required"))
		return
	}
	if !s.requireAdminKey(w, r) {
		return
	}
	limit := 100
	if raw := r.URL.Query().Get("limit"); raw != "" {
		var err error
		limit, err = strconv.Atoi(raw)
		if err != nil || limit < 1 || limit > 100 {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "limit must be between 1 and 100"))
			return
		}
	}
	after := r.URL.Query().Get("after")
	if len(after) > 256 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid cursor"))
		return
	}
	rows, err := s.store.ListSmallModelsInterest(r.Context(), after, limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("storage_error", "could not list interest"))
		return
	}
	next := ""
	if len(rows) == limit {
		next = rows[len(rows)-1].AccountID
	}
	w.Header().Set("Cache-Control", "private, no-store")
	writeJSON(w, http.StatusOK, struct {
		Data []store.SmallModelsInterestContact `json:"data"`
		Next string                             `json:"next_cursor,omitempty"`
	}{Data: rows, Next: next})
}
