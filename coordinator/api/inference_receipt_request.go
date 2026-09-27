package api

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/receipts"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const (
	inferenceReceiptHeader      = "X-Darkbloom-Receipt"
	inferenceReceiptNonceHeader = "X-Darkbloom-Receipt-Nonce"
	inferenceReceiptJobIDHeader = "X-Darkbloom-Receipt-Job-ID"
	inferenceReceiptHashHeader  = "X-Darkbloom-Receipt-Hash"
	inferenceReceiptRequired    = "required"
	// inferenceReceiptStoreTimeout bounds receipt writes that run detached from
	// the request context, so a client disconnect cannot abandon a transition
	// and a stalled store cannot hold the handler indefinitely.
	inferenceReceiptStoreTimeout = 5 * time.Second
)

var errInferenceReceiptUnavailable = errors.New("inference receipt service unavailable")

// inferenceReceiptRequest is the coordinator-side commitment to one opted-in
// request, computed before dispatch from the caller's original plaintext body.
type inferenceReceiptRequest struct {
	JobID              string
	Nonce              string
	CallerRef          string
	RequestSHA256      string
	RequestBytesSHA256 string
	RequestedModel     string
	CreatedAt          time.Time
	LookupExpiresAt    time.Time
}

type inferenceReceiptRequestContextKey struct{}

func withInferenceReceiptRequest(ctx context.Context, request *inferenceReceiptRequest) context.Context {
	if request == nil {
		return ctx
	}
	return context.WithValue(ctx, inferenceReceiptRequestContextKey{}, request)
}

func inferenceReceiptRequestFromContext(ctx context.Context) *inferenceReceiptRequest {
	request, _ := ctx.Value(inferenceReceiptRequestContextKey{}).(*inferenceReceiptRequest)
	return request
}

func hasReceiptRequest(r *http.Request) bool {
	return strings.TrimSpace(r.Header.Get(inferenceReceiptHeader)) != "" || strings.TrimSpace(r.Header.Get(inferenceReceiptNonceHeader)) != ""
}

// newInferenceReceiptRequest validates an opt-in request and commits to its
// body. It returns (nil, nil) when the caller did not ask for a receipt. The
// supported shape is deliberately narrow — non-streaming, plain-text chat with
// no tools or media — because the receipt hashes the assistant text exactly,
// and those other shapes have no single text output to commit to yet.
func (s *Server) newInferenceReceiptRequest(
	r *http.Request,
	parsed map[string]any,
	originalBody []byte,
	endpoint string,
	isResponsesAPI bool,
) (*inferenceReceiptRequest, error) {
	mode := strings.TrimSpace(r.Header.Get(inferenceReceiptHeader))
	nonceHeader := strings.TrimSpace(r.Header.Get(inferenceReceiptNonceHeader))
	if mode == "" && nonceHeader == "" {
		return nil, nil
	}
	if !strings.EqualFold(mode, inferenceReceiptRequired) || nonceHeader == "" {
		return nil, errors.New("receipt requests require X-Darkbloom-Receipt: required and a verifier nonce")
	}
	if s.inferenceReceipts == nil {
		return nil, errInferenceReceiptUnavailable
	}
	if _, ok := s.inferenceReceiptStore(); !ok {
		return nil, errInferenceReceiptUnavailable
	}
	if endpoint != "/v1/chat/completions" || r.URL.Path != "/v1/chat/completions" || isResponsesAPI {
		return nil, errors.New("receipts currently support non-streaming chat completions only")
	}
	if stream, _ := parsed["stream"].(bool); stream {
		return nil, errors.New("receipt-enabled streaming requests are not supported yet")
	}
	if detectMediaRequirement(parsed) || requestHasTools(parsed) {
		return nil, errors.New("receipt-enabled requests currently support plain text without tools only")
	}
	if _, hasToolChoice := parsed["tool_choice"]; hasToolChoice {
		return nil, errors.New("receipt-enabled requests currently support plain text without tools only")
	}
	if _, hasInput := parsed["input"]; hasInput {
		return nil, errors.New("receipts currently support chat completions only")
	}
	messages, ok := parsed["messages"].([]any)
	if !ok || len(messages) == 0 {
		return nil, errors.New("receipt-enabled chat requests require messages")
	}
	for _, item := range messages {
		message, ok := item.(map[string]any)
		if !ok {
			return nil, errors.New("receipt-enabled messages must be plain text objects")
		}
		role, _ := message["role"].(string)
		content, ok := message["content"].(string)
		if !ok || content == "" || (role != "system" && role != "developer" && role != "user" && role != "assistant") {
			return nil, errors.New("receipt-enabled messages must have a supported role and non-empty text content")
		}
	}
	// The nonce is the verifier's freshness challenge, so it must carry full
	// entropy and have exactly one spelling: re-encoding must round-trip.
	nonce, err := base64.RawURLEncoding.DecodeString(nonceHeader)
	if err != nil || len(nonce) != 32 || base64.RawURLEncoding.EncodeToString(nonce) != nonceHeader {
		return nil, errors.New("receipt nonce must be a canonical base64url encoding of 32 random bytes")
	}
	// caller_ref is the key's public ID, never the secret; it lets the caller
	// show which of its keys made the request without revealing credentials.
	callerRef := keyIDFromContext(r.Context())
	if callerRef == "" {
		return nil, errors.New("receipt-enabled requests require an API key with a stable key ID")
	}
	canonicalHash, err := receipts.HashCanonicalJSON(originalBody)
	if err != nil {
		return nil, errors.New("receipt-enabled request JSON cannot be canonicalized")
	}
	now := time.Now().UTC()
	model, _ := parsed["model"].(string)
	return &inferenceReceiptRequest{
		JobID:              uuid.NewString(),
		Nonce:              nonceHeader,
		CallerRef:          callerRef,
		RequestSHA256:      canonicalHash,
		RequestBytesSHA256: receipts.HashBytes(originalBody),
		RequestedModel:     model,
		CreatedAt:          now,
		LookupExpiresAt:    now.Add(s.inferenceReceipts.retention),
	}, nil
}

// rejectInferenceReceiptRequest answers an opt-in request that cannot receive
// a receipt. It never falls back to serving the request without one: the
// caller asked for a receipt as a requirement, not a preference.
func (s *Server) rejectInferenceReceiptRequest(w http.ResponseWriter, err error) {
	if errors.Is(err, errInferenceReceiptUnavailable) {
		s.recordInferenceReceiptRequest("unavailable")
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("receipt_unavailable", "inference receipts are unavailable"))
		return
	}
	s.recordInferenceReceiptRequest("invalid")
	writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", err.Error()))
}

// reserveInferenceReceipt stores the pending row before dispatch. Reserving
// first enforces nonce single use before any provider work is spent, and makes
// the job ID answerable (202 pending) while inference is still running.
func (s *Server) reserveInferenceReceipt(ctx context.Context, request *inferenceReceiptRequest) error {
	receiptStore, ok := s.inferenceReceiptStore()
	if !ok {
		s.recordInferenceReceiptRequest("unavailable")
		return errInferenceReceiptUnavailable
	}
	err := receiptStore.CreateInferenceReceipt(ctx, store.InferenceReceiptRecord{
		JobID:     request.JobID,
		Nonce:     request.Nonce,
		State:     store.InferenceReceiptPending,
		CreatedAt: request.CreatedAt,
		UpdatedAt: request.CreatedAt,
		ExpiresAt: request.LookupExpiresAt,
	})
	switch {
	case errors.Is(err, store.ErrInferenceReceiptConflict):
		s.recordInferenceReceiptRequest("nonce_conflict")
	case err != nil:
		s.recordInferenceReceiptRequest("reserve_failed")
	default:
		s.recordInferenceReceiptRequest("accepted")
		return nil
	}
	return fmt.Errorf("reserve inference receipt: %w", err)
}

// pendingInferenceReceipt builds the per-attempt receipt context. The provider
// body is produced per dispatch attempt, so each attempt hashes its own; the
// receipt then binds the body the winning attempt actually sent.
func pendingInferenceReceipt(request *inferenceReceiptRequest, providerBody []byte) *registry.InferenceReceiptContext {
	if request == nil {
		return nil
	}
	return &registry.InferenceReceiptContext{
		JobID:                 request.JobID,
		Nonce:                 request.Nonce,
		CallerRef:             request.CallerRef,
		RequestSHA256:         request.RequestSHA256,
		RequestBytesSHA256:    request.RequestBytesSHA256,
		ProviderRequestSHA256: receipts.HashBytes(providerBody),
		RequestedModel:        request.RequestedModel,
		CreatedAt:             request.CreatedAt,
		LookupExpiresAt:       request.LookupExpiresAt,
	}
}
