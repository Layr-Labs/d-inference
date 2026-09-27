package api

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/receipts"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const (
	inferenceReceiptHeader        = "X-Darkbloom-Receipt"
	inferenceReceiptNonceHeader   = "X-Darkbloom-Receipt-Nonce"
	inferenceReceiptJobIDHeader   = "X-Darkbloom-Receipt-Job-ID"
	inferenceReceiptHashHeader    = "X-Darkbloom-Receipt-Hash"
	inferenceReceiptRequired      = "required"
	defaultInferenceReceiptExpiry = 90 * 24 * time.Hour
)

var errInferenceReceiptUnavailable = errors.New("inference receipt service unavailable")

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

// configureInferenceReceipts loads the optional coordinator signing key and
// historical public-key ring. Invalid enabled configuration leaves the feature
// unavailable, so no request can receive an unsigned success claim.
func (s *Server) configureInferenceReceipts(cfg ServerConfig) {
	s.inferenceReceiptRetention = defaultInferenceReceiptExpiry
	s.inferenceReceiptIssuer = inferenceReceiptIssuer(cfg.BaseURL)
	s.inferenceReceiptPublicKeys = make(map[string][]byte)
	if !cfg.InferenceReceiptsEnabled {
		return
	}
	var historical map[string]string
	if raw := strings.TrimSpace(cfg.InferenceReceiptPublicKeysJSON); raw != "" {
		if err := json.Unmarshal([]byte(raw), &historical); err != nil {
			s.logger.Error("inference receipt public-key configuration is invalid", "error", err)
			return
		}
	}
	for keyID, encoded := range historical {
		key, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil || len(key) != ed25519.PublicKeySize || strings.TrimSpace(keyID) == "" {
			s.logger.Error("inference receipt public key is invalid", "key_id", keyID)
			return
		}
		s.inferenceReceiptPublicKeys[keyID] = append([]byte(nil), key...)
	}
	keyID := strings.TrimSpace(cfg.InferenceReceiptKeyID)
	privateKey, err := base64.StdEncoding.DecodeString(strings.TrimSpace(cfg.InferenceReceiptSigningKey))
	if err != nil || keyID == "" {
		s.logger.Error("inference receipts enabled without a valid signing key and key ID")
		return
	}
	signer, err := receipts.NewSignerFromBytes(keyID, privateKey)
	if err != nil {
		s.logger.Error("inference receipt signing key is invalid", "error", err)
		return
	}
	publicKey := signer.PublicKey()
	if configured, ok := s.inferenceReceiptPublicKeys[keyID]; ok && !ed25519.PublicKey(configured).Equal(publicKey) {
		s.logger.Error("inference receipt active public key does not match signing key", "key_id", keyID)
		return
	}
	s.inferenceReceiptPublicKeys[keyID] = append([]byte(nil), publicKey...)
	s.inferenceReceiptSigner = signer
	s.inferenceReceiptEnabled = true
}

func inferenceReceiptIssuer(baseURL string) string {
	baseURL = strings.TrimRight(strings.TrimSpace(baseURL), "/")
	if baseURL == "" {
		return "https://api.darkbloom.dev"
	}
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.User != nil {
		return "https://api.darkbloom.dev"
	}
	parsed.Path, parsed.RawQuery, parsed.Fragment = "", "", ""
	return parsed.String()
}

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
	if !s.inferenceReceiptEnabled || s.inferenceReceiptSigner == nil {
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
	var nonce []byte
	var err error
	if nonce, err = base64.RawURLEncoding.DecodeString(nonceHeader); err != nil || len(nonce) != 32 || base64.RawURLEncoding.EncodeToString(nonce) != nonceHeader {
		return nil, errors.New("receipt nonce must be a canonical base64url encoding of 32 random bytes")
	}
	callerRef := keyIDFromContext(r.Context())
	if callerRef == "" {
		return nil, errors.New("receipt-enabled requests require an API key with a stable key ID")
	}
	canonicalHash, err := receipts.HashCanonicalJSON(originalBody)
	if err != nil {
		return nil, errors.New("receipt-enabled request JSON cannot be canonicalized")
	}
	now := time.Now().UTC()
	retention := s.inferenceReceiptRetention
	if retention <= 0 {
		retention = defaultInferenceReceiptExpiry
	}
	model, _ := parsed["model"].(string)
	return &inferenceReceiptRequest{
		JobID:              uuid.NewString(),
		Nonce:              nonceHeader,
		CallerRef:          callerRef,
		RequestSHA256:      canonicalHash,
		RequestBytesSHA256: receipts.HashBytes(originalBody),
		RequestedModel:     model,
		CreatedAt:          now,
		LookupExpiresAt:    now.Add(retention),
	}, nil
}

func hasReceiptRequest(r *http.Request) bool {
	return strings.TrimSpace(r.Header.Get(inferenceReceiptHeader)) != "" || strings.TrimSpace(r.Header.Get(inferenceReceiptNonceHeader)) != ""
}

func (s *Server) createPendingInferenceReceipt(ctx context.Context, request *inferenceReceiptRequest) error {
	if request == nil {
		return nil
	}
	if s.store == nil {
		return errInferenceReceiptUnavailable
	}
	err := s.store.CreateInferenceReceipt(ctx, store.InferenceReceiptRecord{
		JobID:     request.JobID,
		Nonce:     request.Nonce,
		State:     store.InferenceReceiptPending,
		CreatedAt: request.CreatedAt,
		UpdatedAt: request.CreatedAt,
		ExpiresAt: request.LookupExpiresAt,
	})
	if err != nil {
		return fmt.Errorf("create pending inference receipt: %w", err)
	}
	return nil
}

func pendingInferenceReceipt(request *inferenceReceiptRequest, providerBody []byte) *registry.InferenceReceiptContext {
	if request == nil {
		return nil
	}
	return &registry.InferenceReceiptContext{
		JobID: request.JobID, Nonce: request.Nonce, CallerRef: request.CallerRef,
		RequestSHA256: request.RequestSHA256, RequestBytesSHA256: request.RequestBytesSHA256,
		ProviderRequestSHA256: receipts.HashBytes(providerBody), RequestedModel: request.RequestedModel,
		CreatedAt: request.CreatedAt, LookupExpiresAt: request.LookupExpiresAt,
	}
}

func (s *Server) finalizeInferenceReceipt(w http.ResponseWriter, pr *registry.PendingRequest, response any) error {
	if pr == nil || pr.InferenceReceipt == nil {
		return nil
	}
	if !s.inferenceReceiptEnabled || s.inferenceReceiptSigner == nil || s.store == nil {
		return errInferenceReceiptUnavailable
	}
	output, finishReason, err := plainTextReceiptOutput(response)
	if err != nil {
		_ = s.store.SetInferenceReceiptState(context.Background(), pr.InferenceReceipt.JobID, store.InferenceReceiptFailed, time.Now().UTC())
		return err
	}
	completedAt := time.Now().UTC()
	payload := receipts.Payload{
		SchemaVersion:         1,
		Issuer:                s.inferenceReceiptIssuer,
		JobID:                 pr.InferenceReceipt.JobID,
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
	envelope, err := s.inferenceReceiptSigner.Sign(payload)
	if err != nil {
		_ = s.store.SetInferenceReceiptState(context.Background(), pr.InferenceReceipt.JobID, store.InferenceReceiptFailed, completedAt)
		return err
	}
	encoded, err := json.Marshal(envelope)
	if err != nil {
		_ = s.store.SetInferenceReceiptState(context.Background(), pr.InferenceReceipt.JobID, store.InferenceReceiptFailed, completedAt)
		return errors.New("could not encode inference receipt")
	}
	changed, err := s.store.CompleteInferenceReceipt(context.Background(), pr.InferenceReceipt.JobID,
		envelope.ReceiptHash, encoded, completedAt, payload.LookupExpiresAt)
	if err != nil {
		_ = s.store.SetInferenceReceiptState(context.Background(), pr.InferenceReceipt.JobID, store.InferenceReceiptFailed, completedAt)
		return fmt.Errorf("persist completed inference receipt: %w", err)
	}
	if !changed {
		return errors.New("inference receipt was not pending at completion")
	}
	w.Header().Set(inferenceReceiptHashHeader, envelope.ReceiptHash)
	return nil
}

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

func (s *Server) failPendingInferenceReceipt(request *inferenceReceiptRequest) {
	if request == nil || s.store == nil {
		return
	}
	_ = s.store.SetInferenceReceiptState(context.Background(), request.JobID, store.InferenceReceiptFailed, time.Now().UTC())
}

func (s *Server) writeInferenceReceiptFailure(w http.ResponseWriter, pr *registry.PendingRequest) {
	if pr != nil && pr.InferenceReceipt != nil && s.store != nil {
		_ = s.store.SetInferenceReceiptState(context.Background(), pr.InferenceReceipt.JobID, store.InferenceReceiptFailed, time.Now().UTC())
	}
	writeJSON(w, http.StatusBadGateway, errorResponse("receipt_unavailable", "inference completed but its verification receipt could not be recorded"))
}

func (s *Server) handleInferenceReceiptByJobID(w http.ResponseWriter, r *http.Request) {
	record, err := s.store.GetInferenceReceiptByJobID(r.Context(), r.PathValue("job_id"))
	if err != nil || !record.ExpiresAt.After(time.Now()) {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "inference receipt not found"))
		return
	}
	s.writeInferenceReceiptLookup(w, record)
}

func (s *Server) handleInferenceReceiptByHash(w http.ResponseWriter, r *http.Request) {
	record, err := s.store.GetInferenceReceiptByHash(r.Context(), r.PathValue("receipt_hash"))
	if err != nil || !record.ExpiresAt.After(time.Now()) {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "inference receipt not found"))
		return
	}
	s.writeInferenceReceiptLookup(w, record)
}

func (s *Server) writeInferenceReceiptLookup(w http.ResponseWriter, record store.InferenceReceiptRecord) {
	w.Header().Set("Cache-Control", "private, no-store")
	response := inferenceReceiptLookupResponse{JobID: record.JobID, State: record.State}
	if record.State == store.InferenceReceiptCompleted {
		var envelope receipts.Envelope
		if err := json.Unmarshal(record.Envelope, &envelope); err != nil || envelope.ReceiptHash != record.ReceiptHash {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("receipt_unavailable", "stored inference receipt is invalid"))
			return
		}
		publicKey := s.inferenceReceiptPublicKeys[envelope.KeyID]
		if len(publicKey) != ed25519.PublicKeySize || receipts.Verify(envelope, ed25519.PublicKey(publicKey)) != nil {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("receipt_unavailable", "inference receipt signing key is unavailable"))
			return
		}
		response.Receipt = append(json.RawMessage(nil), record.Envelope...)
		writeJSON(w, http.StatusOK, response)
		return
	}
	if record.State == store.InferenceReceiptPending {
		writeJSON(w, http.StatusAccepted, response)
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) handleInferenceReceiptKeys(w http.ResponseWriter, _ *http.Request) {
	if !s.inferenceReceiptEnabled || len(s.inferenceReceiptPublicKeys) == 0 {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("receipt_unavailable", "inference receipts are unavailable"))
		return
	}
	ids := make([]string, 0, len(s.inferenceReceiptPublicKeys))
	for keyID := range s.inferenceReceiptPublicKeys {
		ids = append(ids, keyID)
	}
	sort.Strings(ids)
	response := inferenceReceiptKeysResponse{Issuer: s.inferenceReceiptIssuer}
	for _, keyID := range ids {
		response.Keys = append(response.Keys, inferenceReceiptPublicKey{
			KeyID: keyID, Algorithm: "Ed25519",
			PublicKey: base64.StdEncoding.EncodeToString(s.inferenceReceiptPublicKeys[keyID]),
		})
	}
	w.Header().Set("Cache-Control", "public, max-age=300")
	writeJSON(w, http.StatusOK, response)
}
