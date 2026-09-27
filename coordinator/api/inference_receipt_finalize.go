package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/receipts"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// finalizeInferenceReceipt signs and persists the receipt for the committed
// attempt, then sets the receipt-hash response header. It runs after usage has
// arrived and before the body is written, so a caller that required a receipt
// never receives output without one. A non-nil error means the caller must
// answer with writeInferenceReceiptFailure instead of the response.
func (s *Server) finalizeInferenceReceipt(w http.ResponseWriter, pr *registry.PendingRequest, response any) error {
	if pr == nil || pr.InferenceReceipt == nil {
		return nil
	}
	receiptStore, ok := s.inferenceReceiptStore()
	if s.inferenceReceipts == nil || !ok {
		s.recordInferenceReceiptFinalize("unavailable")
		return errInferenceReceiptUnavailable
	}
	jobID := pr.InferenceReceipt.JobID
	output, finishReason, err := plainTextReceiptOutput(response)
	if err != nil {
		s.recordInferenceReceiptFinalize("unsupported_output")
		s.markInferenceReceiptFailed(jobID)
		return err
	}
	completedAt := time.Now().UTC()
	payload := receipts.Payload{
		SchemaVersion:         1,
		Issuer:                s.inferenceReceipts.origin,
		JobID:                 jobID,
		WinningAttemptID:      pr.RequestID,
		Nonce:                 pr.InferenceReceipt.Nonce,
		CallerRef:             pr.InferenceReceipt.CallerRef,
		RequestSHA256:         pr.InferenceReceipt.RequestSHA256,
		RequestBytesSHA256:    pr.InferenceReceipt.RequestBytesSHA256,
		ProviderRequestSHA256: pr.InferenceReceipt.ProviderRequestSHA256,
		RequestedModel:        pr.InferenceReceipt.RequestedModel,
		ResolvedModel:         pr.Model,
		OutputSHA256:          receipts.HashBytes([]byte(output)),
		Status:                "completed",
		FinishReason:          finishReason,
		CompletedAt:           completedAt,
		LookupExpiresAt:       pr.InferenceReceipt.LookupExpiresAt,
	}
	envelope, err := s.inferenceReceipts.keys.Signer().Sign(payload)
	if err != nil {
		s.recordInferenceReceiptFinalize("sign_failed")
		s.markInferenceReceiptFailed(jobID)
		return err
	}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		s.recordInferenceReceiptFinalize("sign_failed")
		s.markInferenceReceiptFailed(jobID)
		return errors.New("could not encode inference receipt")
	}
	ctx, cancel := context.WithTimeout(context.Background(), inferenceReceiptStoreTimeout)
	changed, err := receiptStore.CompleteInferenceReceipt(ctx, jobID,
		envelope.ReceiptHash, encoded, completedAt, payload.LookupExpiresAt)
	cancel()
	if err != nil {
		s.recordInferenceReceiptFinalize("persist_failed")
		s.markInferenceReceiptFailed(jobID)
		return fmt.Errorf("persist completed inference receipt: %w", err)
	}
	if !changed {
		// Another attempt already finished this job (or maintenance marked it
		// interrupted). Only the stored receipt is authoritative, so this
		// attempt must not claim a hash the store never accepted.
		s.recordInferenceReceiptFinalize("not_pending")
		return errors.New("inference receipt was not pending at completion")
	}
	s.recordInferenceReceiptFinalize("completed")
	w.Header().Set(inferenceReceiptHashHeader, envelope.ReceiptHash)
	return nil
}

// plainTextReceiptOutput extracts the single assistant text the receipt
// commits to. It works on the response exactly as it will be serialized to the
// caller, so output_sha256 matches the bytes the caller received.
func plainTextReceiptOutput(response any) (string, string, error) {
	encoded, err := json.Marshal(response)
	if err != nil {
		return "", "", errors.New("could not encode completed chat response")
	}
	var body map[string]any
	if err := json.Unmarshal(encoded, &body); err != nil {
		return "", "", errors.New("completed response is not a JSON object")
	}
	choices, ok := body["choices"].([]any)
	if !ok || len(choices) != 1 {
		return "", "", errors.New("receipt requires exactly one completed choice")
	}
	choice, ok := choices[0].(map[string]any)
	if !ok {
		return "", "", errors.New("completed choice has an invalid shape")
	}
	message, ok := choice["message"].(map[string]any)
	if !ok {
		return "", "", errors.New("receipt requires a completed assistant message")
	}
	content, ok := message["content"].(string)
	if !ok {
		return "", "", errors.New("receipt requires a plain-text assistant response")
	}
	if _, hasTools := message["tool_calls"]; hasTools {
		return "", "", errors.New("tool-call responses are not supported by inference receipts yet")
	}
	finish, ok := choice["finish_reason"].(string)
	if !ok || (finish != "stop" && finish != "length") {
		return "", "", errors.New("receipt requires a supported completion finish reason")
	}
	return content, finish, nil
}

// failPendingInferenceReceipt is deferred by the chat handler once a pending
// row exists. Every exit that did not complete the receipt (provider error,
// timeout, client gone) leaves the job failed rather than pending; after a
// completion the store ignores it.
func (s *Server) failPendingInferenceReceipt(request *inferenceReceiptRequest) {
	if request == nil {
		return
	}
	s.markInferenceReceiptFailed(request.JobID)
}

// markInferenceReceiptFailed moves a pending receipt to failed. Terminal rows
// are left unchanged by the store, so calling it after completion is a no-op.
func (s *Server) markInferenceReceiptFailed(jobID string) {
	receiptStore, ok := s.inferenceReceiptStore()
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), inferenceReceiptStoreTimeout)
	defer cancel()
	if err := receiptStore.SetInferenceReceiptState(ctx, jobID, store.InferenceReceiptFailed, time.Now().UTC()); err != nil {
		s.logger.Warn("inference receipt failure state was not recorded", "job_id", jobID, "error", err)
	}
}

// writeInferenceReceiptFailure answers a completed inference whose receipt
// could not be recorded. The output is withheld: the caller required a receipt.
func (s *Server) writeInferenceReceiptFailure(w http.ResponseWriter, pr *registry.PendingRequest) {
	if pr != nil && pr.InferenceReceipt != nil {
		s.markInferenceReceiptFailed(pr.InferenceReceipt.JobID)
	}
	writeJSON(w, http.StatusBadGateway, errorResponse("receipt_unavailable", "inference completed but its verification receipt could not be recorded"))
}
