package api

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/receipts"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// reservedReceiptAttempt stores a pending row and returns the winning attempt
// that will finalize it.
func reservedReceiptAttempt(t *testing.T, st *store.MemoryStore, jobID string) *registry.PendingRequest {
	t.Helper()
	now := time.Now().UTC().Truncate(time.Second)
	receipt := &registry.InferenceReceiptContext{
		JobID:                 jobID,
		Nonce:                 apiTestReceiptNonce(),
		CallerRef:             "key-agent",
		RequestSHA256:         strings.Repeat("a", 64),
		RequestBytesSHA256:    strings.Repeat("b", 64),
		ProviderRequestSHA256: strings.Repeat("c", 64),
		RequestedModel:        "gemma-4-26b",
		CreatedAt:             now,
		LookupExpiresAt:       now.Add(defaultInferenceReceiptExpiry),
	}
	if err := st.CreateInferenceReceipt(context.Background(), store.InferenceReceiptRecord{
		JobID: jobID, Nonce: receipt.Nonce, State: store.InferenceReceiptPending,
		CreatedAt: now, UpdatedAt: now, ExpiresAt: receipt.LookupExpiresAt,
	}); err != nil {
		t.Fatal(err)
	}
	return &registry.PendingRequest{
		RequestID: "winning-attempt-id", Model: "resolved-build-id", PublicModel: "gemma-4-26b",
		InferenceReceipt: receipt,
	}
}

func plainTextChatResponse(content, finish string) map[string]any {
	return map[string]any{"model": "gemma-4-26b", "choices": []any{
		map[string]any{"message": map[string]any{"role": "assistant", "content": content}, "finish_reason": finish},
	}}
}

func TestInferenceReceiptFinalizationSignsCommittedRequestAndOutput(t *testing.T) {
	issuer, privateKey := randomReceiptIssuer(t)
	st := store.NewMemory(store.Config{})
	s := newReceiptTestServer(st, issuer)
	pr := reservedReceiptAttempt(t, st, "job-receipt-test")

	w := httptest.NewRecorder()
	if err := s.finalizeInferenceReceipt(w, pr, plainTextChatResponse("4", "stop")); err != nil {
		t.Fatalf("finalizeInferenceReceipt: %v", err)
	}
	if got := w.Header().Get(inferenceReceiptHashHeader); got == "" {
		t.Fatal("missing receipt hash response header")
	}
	record, err := st.GetInferenceReceiptByJobID(context.Background(), pr.InferenceReceipt.JobID)
	if err != nil {
		t.Fatal(err)
	}
	var envelope receipts.Envelope
	if err := json.Unmarshal(record.Envelope, &envelope); err != nil {
		t.Fatal(err)
	}
	if err := receipts.Verify(envelope, privateKey.Public().(ed25519.PublicKey)); err != nil {
		t.Fatalf("Verify: %v", err)
	}
	payload, want := envelope.Payload, pr.InferenceReceipt
	if payload.JobID != want.JobID || payload.WinningAttemptID != pr.RequestID || payload.Nonce != want.Nonce || payload.CallerRef != want.CallerRef {
		t.Fatalf("receipt identity mismatch: %+v", payload)
	}
	if payload.RequestSHA256 != want.RequestSHA256 || payload.RequestBytesSHA256 != want.RequestBytesSHA256 || payload.ProviderRequestSHA256 != want.ProviderRequestSHA256 {
		t.Fatalf("receipt omitted request commitments: %+v", payload)
	}
	if payload.OutputSHA256 != receipts.HashBytes([]byte("4")) || payload.RequestedModel != "gemma-4-26b" || payload.ResolvedModel != "resolved-build-id" || payload.FinishReason != "stop" {
		t.Fatalf("receipt output/model mismatch: %+v", payload)
	}
	if payload.Issuer != receiptTestIssuer {
		t.Fatalf("issuer = %q, want %q", payload.Issuer, receiptTestIssuer)
	}
	if record.ReceiptHash != envelope.ReceiptHash || record.State != store.InferenceReceiptCompleted {
		t.Fatalf("stored envelope mismatch: %+v", record)
	}
	if got := receiptMetricCount(s, "inference_receipt_finalize_total", MetricLabel{"outcome", "completed"}); got != 1 {
		t.Fatalf("completed finalize metric = %d, want 1", got)
	}
}

func TestInferenceReceiptFinalizationFailsClosedOnUnsupportedOutput(t *testing.T) {
	issuer, _ := randomReceiptIssuer(t)
	st := store.NewMemory(store.Config{})
	s := newReceiptTestServer(st, issuer)
	pr := reservedReceiptAttempt(t, st, "job-invalid-output")

	err := s.finalizeInferenceReceipt(httptest.NewRecorder(), pr, map[string]any{"choices": []any{map[string]any{"message": map[string]any{"tool_calls": []any{}}}}})
	if err == nil {
		t.Fatal("receipt finalized without a plain-text assistant output")
	}
	record, getErr := st.GetInferenceReceiptByJobID(context.Background(), pr.InferenceReceipt.JobID)
	if getErr != nil || record.State != store.InferenceReceiptFailed {
		t.Fatalf("unsupported output was not marked failed: (%+v, %v)", record, getErr)
	}
	if got := receiptMetricCount(s, "inference_receipt_finalize_total", MetricLabel{"outcome", "unsupported_output"}); got != 1 {
		t.Fatalf("unsupported_output finalize metric = %d, want 1", got)
	}
}

func TestInferenceReceiptFinalizationLateAttemptCannotClaimHash(t *testing.T) {
	issuer, _ := randomReceiptIssuer(t)
	st := store.NewMemory(store.Config{})
	s := newReceiptTestServer(st, issuer)
	pr := reservedReceiptAttempt(t, st, "job-raced")
	if err := s.finalizeInferenceReceipt(httptest.NewRecorder(), pr, plainTextChatResponse("4", "stop")); err != nil {
		t.Fatalf("winning finalize: %v", err)
	}
	late := &registry.PendingRequest{
		RequestID: "late-backup-attempt", Model: pr.Model, PublicModel: pr.PublicModel,
		InferenceReceipt: pr.InferenceReceipt,
	}
	w := httptest.NewRecorder()
	if err := s.finalizeInferenceReceipt(w, late, plainTextChatResponse("four", "stop")); err == nil {
		t.Fatal("late attempt finalized an already completed receipt")
	}
	if got := w.Header().Get(inferenceReceiptHashHeader); got != "" {
		t.Fatalf("late attempt advertised receipt hash %q", got)
	}
	if got := receiptMetricCount(s, "inference_receipt_finalize_total", MetricLabel{"outcome", "not_pending"}); got != 1 {
		t.Fatalf("not_pending finalize metric = %d, want 1", got)
	}
}
