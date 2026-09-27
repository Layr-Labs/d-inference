package api

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/receipts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Public receipt lookup. The job and hash routes need no API key: a job ID is
// a random UUID and a receipt hash is a SHA-256, so neither is guessable, and
// the response carries digests and metadata only, never prompt or output text.

type inferenceReceiptLookupResponse struct {
	JobID   string          `json:"job_id"`
	State   string          `json:"state"`
	Receipt json.RawMessage `json:"receipt,omitempty"`
}

type inferenceReceiptPublicKey struct {
	KeyID     string `json:"key_id"`
	Algorithm string `json:"algorithm"`
	PublicKey string `json:"public_key"`
}

type inferenceReceiptKeysResponse struct {
	Issuer string                      `json:"issuer"`
	Keys   []inferenceReceiptPublicKey `json:"keys"`
}

func (s *Server) handleInferenceReceiptByJobID(w http.ResponseWriter, r *http.Request) {
	receiptStore, ok := s.inferenceReceiptStore()
	if !ok {
		s.writeInferenceReceiptLookupUnavailable(w, "job")
		return
	}
	record, err := receiptStore.GetInferenceReceiptByJobID(r.Context(), r.PathValue("job_id"))
	s.writeInferenceReceiptLookup(w, "job", record, err)
}

func (s *Server) handleInferenceReceiptByHash(w http.ResponseWriter, r *http.Request) {
	receiptStore, ok := s.inferenceReceiptStore()
	if !ok {
		s.writeInferenceReceiptLookupUnavailable(w, "hash")
		return
	}
	record, err := receiptStore.GetInferenceReceiptByHash(r.Context(), r.PathValue("receipt_hash"))
	s.writeInferenceReceiptLookup(w, "hash", record, err)
}

// writeInferenceReceiptLookup answers a job or hash lookup. Only a true miss or
// an expired row is 404; a transient store failure is 503 so a verifier never
// mistakes an outage for proof that a receipt does not exist. Expiry is
// enforced here as well as by pruning, so a row awaiting the hourly sweep is
// already hidden.
func (s *Server) writeInferenceReceiptLookup(w http.ResponseWriter, route string, record store.InferenceReceiptRecord, err error) {
	w.Header().Set("Cache-Control", "private, no-store")
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.logger.Error("inference receipt lookup failed", "route", route, "error", err)
		s.recordInferenceReceiptLookup(route, "store_error")
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("receipt_unavailable", "inference receipt lookup is unavailable"))
		return
	}
	if err != nil || !record.ExpiresAt.After(time.Now()) {
		s.recordInferenceReceiptLookup(route, "not_found")
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "inference receipt not found"))
		return
	}
	response := inferenceReceiptLookupResponse{JobID: record.JobID, State: record.State}
	switch record.State {
	case store.InferenceReceiptCompleted:
		// Re-verify before serving: a corrupted row or a key dropped from the
		// ring during rotation must surface as 503, never as a receipt that
		// the caller's own verification would reject.
		var envelope receipts.Envelope
		if err := json.Unmarshal(record.Envelope, &envelope); err != nil || envelope.ReceiptHash != record.ReceiptHash {
			s.recordInferenceReceiptLookup(route, "invalid_record")
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("receipt_unavailable", "stored inference receipt is invalid"))
			return
		}
		publicKey, ok := s.inferenceReceipts.publicKey(envelope.KeyID)
		if !ok || receipts.Verify(envelope, publicKey) != nil {
			s.recordInferenceReceiptLookup(route, "key_unavailable")
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("receipt_unavailable", "inference receipt signing key is unavailable"))
			return
		}
		response.Receipt = append(json.RawMessage(nil), record.Envelope...)
		s.recordInferenceReceiptLookup(route, "completed")
		writeJSON(w, http.StatusOK, response)
	case store.InferenceReceiptPending:
		s.recordInferenceReceiptLookup(route, "pending")
		writeJSON(w, http.StatusAccepted, response)
	default:
		s.recordInferenceReceiptLookup(route, "terminal")
		writeJSON(w, http.StatusOK, response)
	}
}

func (s *Server) writeInferenceReceiptLookupUnavailable(w http.ResponseWriter, route string) {
	w.Header().Set("Cache-Control", "private, no-store")
	s.recordInferenceReceiptLookup(route, "unavailable")
	writeJSON(w, http.StatusServiceUnavailable, errorResponse("receipt_unavailable", "inference receipts are unavailable"))
}

// handleInferenceReceiptKeys publishes every verification key a stored receipt
// may still reference, so verifiers can check receipts signed before a
// rotation. The set changes only on redeploy, hence the short public cache.
func (s *Server) handleInferenceReceiptKeys(w http.ResponseWriter, _ *http.Request) {
	if s.inferenceReceipts == nil {
		s.recordInferenceReceiptLookup("keys", "unavailable")
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("receipt_unavailable", "inference receipts are unavailable"))
		return
	}
	response := inferenceReceiptKeysResponse{Issuer: s.inferenceReceipts.origin}
	for _, keyID := range s.inferenceReceipts.keys.KeyIDs() {
		publicKey, _ := s.inferenceReceipts.keys.PublicKey(keyID)
		response.Keys = append(response.Keys, inferenceReceiptPublicKey{
			KeyID:     keyID,
			Algorithm: "Ed25519",
			PublicKey: base64.StdEncoding.EncodeToString(publicKey),
		})
	}
	s.recordInferenceReceiptLookup("keys", "served")
	w.Header().Set("Cache-Control", "public, max-age=300")
	writeJSON(w, http.StatusOK, response)
}
