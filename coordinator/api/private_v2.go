package api

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

const (
	privateV2Version           = "private_v2"
	privateV2PrivacyTier       = "private-v2-process-bound"
	legacyPrivacyTier          = "legacy-coordinator-decryptable"
	privateV2LeaseTTL          = 60 * time.Second
	privateV2LeaseCapacity     = 8192
	privateV2ChunkBuffer       = 64
	privateV2MaxResponseChunks = 8192
	privateV2PerConsumerLeases = 8
	privateV2MaxResponseBytes  = 64 << 20
)

var rawBase64URL = base64.RawURLEncoding

var (
	errPrivateV2LeaseNotFound = errors.New("private-v2 lease not found")
	errPrivateV2LeaseExpired  = errors.New("private-v2 lease expired")
	errPrivateV2LeaseConsumer = errors.New("private-v2 consumer mismatch")
	errPrivateV2RequestID     = errors.New("private-v2 request id mismatch")
	errPrivateV2LeaseCapacity = errors.New("private-v2 lease capacity exhausted")
)

type privateV2Transcript struct {
	Deadline                 string `json:"deadline"`
	Endpoint                 string `json:"endpoint"`
	LeaseID                  string `json:"lease_id"`
	Model                    string `json:"model"`
	ModelGeneration          uint64 `json:"model_generation"`
	ModelManifestHash        string `json:"model_manifest_hash"`
	OwnerBinding             string `json:"owner_binding"`
	ProcessCertificateDigest string `json:"process_certificate_digest"`
	ReleaseBinaryHash        string `json:"release_binary_hash"`
	ReleaseGeneration        uint64 `json:"release_generation"`
	RequestID                string `json:"request_id"`
	RequestedMaxOutputTokens uint64 `json:"requested_max_output_tokens"`
	RequiresVision           bool   `json:"requires_vision"`
	RouteID                  string `json:"route_id"`
	RouteMode                string `json:"route_mode"`
}

type privateV2Lease struct {
	ConsumerHash    [32]byte
	Provider        registry.PrivateV2ProviderSnapshot
	Transcript      privateV2Transcript
	TranscriptBytes []byte
	TranscriptHash  [32]byte
	KDFSalt         [32]byte
	Stream          bool
	ExpiresAt       time.Time
	RequestedMax    int
	RequestedModel  string
}

type privateV2LeaseManager struct {
	mu       sync.Mutex
	leases   map[string]*privateV2Lease
	capacity int
	now      func() time.Time
}

func newPrivateV2LeaseManager(capacity int) *privateV2LeaseManager {
	if capacity <= 0 {
		capacity = privateV2LeaseCapacity
	}
	return &privateV2LeaseManager{leases: make(map[string]*privateV2Lease), capacity: capacity, now: time.Now}
}

func (m *privateV2LeaseManager) cleanupExpiredLocked(now time.Time) {
	for id, lease := range m.leases {
		if lease == nil || !now.Before(lease.ExpiresAt) {
			delete(m.leases, id)
		}
	}
}

func privateV2ConsumerHash(consumerID string) [32]byte {
	return sha256.Sum256([]byte(consumerID))
}

func (m *privateV2LeaseManager) put(lease *privateV2Lease) error {
	if lease == nil || lease.Transcript.LeaseID == "" {
		return errPrivateV2LeaseNotFound
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cleanupExpiredLocked(m.now())
	if len(m.leases) >= m.capacity {
		return errPrivateV2LeaseCapacity
	}
	outstanding := 0
	for _, existing := range m.leases {
		if existing != nil && existing.ConsumerHash == lease.ConsumerHash {
			outstanding++
		}
	}
	if outstanding >= privateV2PerConsumerLeases {
		return errPrivateV2LeaseCapacity
	}
	if _, exists := m.leases[lease.Transcript.LeaseID]; exists {
		return errPrivateV2LeaseCapacity
	}
	m.leases[lease.Transcript.LeaseID] = lease
	return nil
}

func (m *privateV2LeaseManager) consume(leaseID, requestID, consumerID string) (*privateV2Lease, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	now := m.now()
	lease := m.leases[leaseID]
	if lease == nil {
		m.cleanupExpiredLocked(now)
		return nil, errPrivateV2LeaseNotFound
	}
	if !now.Before(lease.ExpiresAt) {
		delete(m.leases, leaseID)
		return nil, errPrivateV2LeaseExpired
	}
	if lease.ConsumerHash != privateV2ConsumerHash(consumerID) {
		return nil, errPrivateV2LeaseConsumer
	}
	if lease.Transcript.RequestID != requestID {
		return nil, errPrivateV2RequestID
	}
	delete(m.leases, leaseID)
	return lease, nil
}

func (m *privateV2LeaseManager) invalidateProvider(providerID string) {
	if m == nil || providerID == "" {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, lease := range m.leases {
		if lease == nil || lease.Provider.ProviderID == providerID {
			delete(m.leases, id)
		}
	}
}

func canonicalPrivateV2Transcript(t privateV2Transcript) ([]byte, error) {
	// A map is intentional: encoding/json emits string keys in lexical order,
	// which is the private-v2 cross-language canonicalization rule.
	return json.Marshal(map[string]any{
		"deadline": t.Deadline, "endpoint": t.Endpoint, "lease_id": t.LeaseID,
		"model": t.Model, "model_generation": t.ModelGeneration,
		"model_manifest_hash": t.ModelManifestHash, "owner_binding": t.OwnerBinding,
		"process_certificate_digest": t.ProcessCertificateDigest,
		"release_binary_hash":        t.ReleaseBinaryHash,
		"release_generation":         t.ReleaseGeneration, "request_id": t.RequestID,
		"requested_max_output_tokens": t.RequestedMaxOutputTokens,
		"requires_vision":             t.RequiresVision, "route_id": t.RouteID,
		"route_mode": t.RouteMode,
	})
}

func canonicalPrivateV2ProcessCertificate(c registry.PrivateV2ProcessCertificate) ([]byte, error) {
	return json.Marshal(map[string]any{
		"backend": c.Backend, "expires_at": privateV2Time(c.ExpiresAt),
		"mda_der_chain": c.MDADERChain,
		"metallib_hash": c.MetallibHash, "mlx_nax": c.MLXNAX,
		"platform": c.Platform, "policy_generation": c.PolicyGeneration,
		"process_evidence_signature":  c.ProcessEvidenceSignature,
		"process_evidence_transcript": c.ProcessEvidenceTranscript,
		"process_public_key":          c.ProcessPublicKey, "provider_version": c.ProviderVersion,
		"release_binary_hash": c.ReleaseBinaryHash, "runtime_hash": c.RuntimeHash,
		"se_public_key": c.SEPublicKey,
		"verified_at":   privateV2Time(c.VerifiedAt), "version": c.Version,
	})
}

func privateV2Time(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }

func privateV2Random(size int) (string, error) {
	b := make([]byte, size)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return rawBase64URL.EncodeToString(b), nil
}

func privateV2RandomSalt() ([32]byte, error) {
	var salt [32]byte
	_, err := rand.Read(salt[:])
	return salt, err
}

func privateV2CanonicalBinary(value string, size, maxSize int) ([]byte, bool) {
	if value == "" || strings.ContainsAny(value, "=\r\n\t ") {
		return nil, false
	}
	decoded, err := rawBase64URL.DecodeString(value)
	if err != nil || rawBase64URL.EncodeToString(decoded) != value {
		return nil, false
	}
	if size > 0 && len(decoded) != size {
		return nil, false
	}
	if maxSize > 0 && len(decoded) > maxSize {
		return nil, false
	}
	return decoded, true
}

func validPrivateV2Endpoint(endpoint string) bool {
	switch endpoint {
	case "chat.completions", "responses", "completions", "messages":
		return true
	default:
		return false
	}
}

func privateV2CanonicalProcessPublicKey(value string) bool {
	decoded, err := base64.StdEncoding.DecodeString(value)
	return err == nil && len(decoded) == 32 &&
		base64.StdEncoding.EncodeToString(decoded) == value
}

func decodePrivateV2JSON(w http.ResponseWriter, r *http.Request, maxBytes int64, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("invalid_request_error", "private-v2 request body is too large"))
		} else {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid private-v2 JSON body"))
		}
		return false
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid private-v2 JSON body"))
		return false
	}
	return true
}

type privateV2PreflightRequest struct {
	Model                    string `json:"model"`
	Endpoint                 string `json:"endpoint"`
	Stream                   bool   `json:"stream"`
	RequestedMaxOutputTokens int    `json:"requested_max_output_tokens"`
	RequiresVision           bool   `json:"requires_vision"`
}

type privateV2PreflightResponse struct {
	Version                  string                               `json:"version"`
	LeaseID                  string                               `json:"lease_id"`
	RequestID                string                               `json:"request_id"`
	RouteID                  string                               `json:"route_id"`
	Model                    string                               `json:"model"`
	Endpoint                 string                               `json:"endpoint"`
	Stream                   bool                                 `json:"stream"`
	ProcessPublicKey         string                               `json:"process_public_key"`
	KDFSalt                  string                               `json:"kdf_salt"`
	TranscriptDigest         string                               `json:"transcript_digest"`
	ProcessCertificate       registry.PrivateV2ProcessCertificate `json:"process_certificate"`
	ModelManifestHash        string                               `json:"model_manifest_hash"`
	ReleaseGeneration        uint64                               `json:"release_generation"`
	ModelGeneration          uint64                               `json:"model_generation"`
	ExpiresAt                string                               `json:"expires_at"`
	RequestedMaxOutputTokens uint64                               `json:"requested_max_output_tokens"`
	RequiresVision           bool                                 `json:"requires_vision"`
	RouteMode                string                               `json:"route_mode"`
	OwnerBinding             string                               `json:"owner_binding"`
}

func (s *Server) privateV2Leases() *privateV2LeaseManager {
	s.privateLeaseMu.Lock()
	defer s.privateLeaseMu.Unlock()
	if s.privateLeases == nil {
		s.privateLeases = newPrivateV2LeaseManager(privateV2LeaseCapacity)
	}
	return s.privateLeases
}

func privateV2RouteBinding(policy selfRoutePolicy) (string, string) {
	if policy.enabled {
		hash := privateV2ConsumerHash(policy.ownerAccountID)
		return "self_route_only", rawBase64URL.EncodeToString(hash[:])
	}
	if policy.prefer {
		hash := privateV2ConsumerHash(policy.ownerAccountID)
		return "prefer_owner", rawBase64URL.EncodeToString(hash[:])
	}
	return "public", ""
}
func validPrivateV2MaxOutputTokens(tokens int) bool {
	return tokens > 0 && uint64(tokens) <= protocol.PrivateV2MaxOutputTokens
}

func (s *Server) handlePrivateV2Preflight(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Darkbloom-Privacy-Tier", privateV2PrivacyTier)
	consumerID := consumerKeyFromContext(r.Context())
	if consumerID == "" {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	var input privateV2PreflightRequest
	if !decodePrivateV2JSON(w, r, maxControlPlaneBodyBytes, &input) {
		return
	}
	input.Model = strings.TrimSpace(input.Model)
	if input.Model == "" || !validPrivateV2Endpoint(input.Endpoint) ||
		!validPrivateV2MaxOutputTokens(input.RequestedMaxOutputTokens) {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid private-v2 preflight"))
		return
	}
	if !s.keyModelAllowed(r.Context(), input.Model) {
		writeJSON(w, http.StatusForbidden, errorResponse("model_not_allowed", "this API key is not allowed to use the requested model"))
		return
	}
	policy := s.resolveSelfRoutePolicy(r)
	routeMode, ownerBinding := privateV2RouteBinding(policy)
	traits := registry.RequestTraits{RequiresPrivateV2: true}
	model, _, ok := s.registry.ResolveModelConstrainedWithTraits(
		input.Model, nil, policy.ownerAccountID, policy.enabled, policy.prefer, traits)
	if !ok || model == "" {
		writeJSON(w, http.StatusNotFound, errorResponse("model_not_found", "model is not available for the authenticated route policy"))
		return
	}
	requestID, err := privateV2Random(24)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create request"))
		return
	}
	probe := &registry.PendingRequest{RequestID: requestID, Model: model, PublicModel: input.Model,
		ConsumerKey: consumerID, RequestedMaxTokens: input.RequestedMaxOutputTokens,
		Traits: traits, RequiresVision: input.RequiresVision,
		SelfRouteOnly: policy.enabled, PreferOwner: policy.prefer,
		OwnerAccountID: policy.ownerAccountID, FreeSelfRoute: policy.enabled}
	_, snapshot, _ := s.registry.SelectPrivateV2Provider(model, probe)
	if snapshot.ProviderID == "" {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("provider_unavailable", "no certified private-v2 provider is available"))
		return
	}

	now := time.Now()
	if !privateV2CanonicalProcessPublicKey(snapshot.Certificate.ProcessPublicKey) {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("provider_unavailable", "provider process key is invalid"))
		return
	}
	expiresAt := now.Add(privateV2LeaseTTL)
	if snapshot.Certificate.ExpiresAt.Before(expiresAt) {
		expiresAt = snapshot.Certificate.ExpiresAt
	}
	if !expiresAt.After(now) {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("provider_unavailable", "provider process certificate expired"))
		return
	}
	leaseID, err := privateV2Random(24)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create lease"))
		return
	}
	routeID, err := privateV2Random(24)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create route"))
		return
	}
	salt, err := privateV2RandomSalt()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create lease"))
		return
	}
	certBytes, err := canonicalPrivateV2ProcessCertificate(snapshot.Certificate)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to certify process"))
		return
	}
	certHash := sha256.Sum256(certBytes)
	transcript := privateV2Transcript{
		Deadline: privateV2Time(expiresAt), Endpoint: input.Endpoint, LeaseID: leaseID,
		Model: model, ModelGeneration: snapshot.ModelGeneration,
		ModelManifestHash: snapshot.ModelManifestHash, OwnerBinding: ownerBinding,
		ProcessCertificateDigest: rawBase64URL.EncodeToString(certHash[:]),
		ReleaseBinaryHash:        snapshot.Certificate.ReleaseBinaryHash,
		ReleaseGeneration:        snapshot.ReleaseGeneration, RequestID: requestID,
		RequestedMaxOutputTokens: uint64(input.RequestedMaxOutputTokens),
		RequiresVision:           input.RequiresVision, RouteID: routeID, RouteMode: routeMode,
	}
	transcriptBytes, err := canonicalPrivateV2Transcript(transcript)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create transcript"))
		return
	}
	transcriptHash := sha256.Sum256(transcriptBytes)
	lease := &privateV2Lease{ConsumerHash: privateV2ConsumerHash(consumerID),
		RequestedModel: input.Model, Provider: snapshot, Transcript: transcript,
		TranscriptBytes: transcriptBytes, TranscriptHash: transcriptHash, KDFSalt: salt,
		Stream: input.Stream, ExpiresAt: expiresAt, RequestedMax: input.RequestedMaxOutputTokens}
	if err := s.privateV2Leases().put(lease); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("provider_unavailable", "private-v2 lease capacity unavailable"))
		return
	}
	writeJSON(w, http.StatusOK, privateV2PreflightResponse{
		Version: privateV2Version, LeaseID: leaseID, RequestID: requestID, RouteID: routeID,
		Model: model, Endpoint: input.Endpoint, Stream: input.Stream,
		ProcessPublicKey:   snapshot.Certificate.ProcessPublicKey,
		KDFSalt:            rawBase64URL.EncodeToString(salt[:]),
		TranscriptDigest:   rawBase64URL.EncodeToString(transcriptHash[:]),
		ProcessCertificate: snapshot.Certificate, ModelManifestHash: snapshot.ModelManifestHash,
		ReleaseGeneration: snapshot.ReleaseGeneration, ModelGeneration: snapshot.ModelGeneration,
		RequestedMaxOutputTokens: uint64(input.RequestedMaxOutputTokens),
		RequiresVision:           input.RequiresVision, RouteMode: routeMode, OwnerBinding: ownerBinding,
		ExpiresAt: privateV2Time(expiresAt),
	})
}

type privateV2SubmitRequest struct {
	Version         string `json:"version"`
	LeaseID         string `json:"lease_id"`
	RequestID       string `json:"request_id"`
	ClientPublicKey string `json:"client_public_key"`
	Nonce           string `json:"nonce"`
	Ciphertext      string `json:"ciphertext"`
}

func (s *Server) handlePrivateV2PendingDisconnect(pr *registry.PendingRequest) {
	if pr == nil {
		return
	}
	pr.ResolvePrivateV2Delivery()
	time.AfterFunc(s.terminalSettleGrace(), func() {
		closePrivateV2SettledChannel(pr)
	})
	saferun.Go(s.logger, "privateV2ProviderDisconnect", func() {
		s.refundReservedBalance(pr, "private-v2-provider-disconnect")
		pr.MarkReservationFinalized()
		closePrivateV2SettledChannel(pr)
	})
}

func (s *Server) privateV2EarlyCleanup(provider *registry.Provider, pr *registry.PendingRequest, reference string) {
	if provider == nil || pr == nil {
		return
	}
	if removed := provider.RemovePending(pr.RequestID); removed != nil {
		s.registry.SetProviderIdle(provider.ID)
		s.refundReservedBalance(pr, reference)
	}
}

func (s *Server) handlePrivateV2Submit(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Darkbloom-Privacy-Tier", privateV2PrivacyTier)
	consumerID := consumerKeyFromContext(r.Context())
	if consumerID == "" {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "authentication required"))
		return
	}
	var input privateV2SubmitRequest
	if !decodePrivateV2JSON(w, r, maxRequestBodyBytes, &input) {
		return
	}
	if input.Version != privateV2Version || input.LeaseID == "" || input.RequestID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid private-v2 request"))
		return
	}
	if _, ok := privateV2CanonicalBinary(input.ClientPublicKey, 32, 32); !ok {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid client_public_key"))
		return
	}
	if _, ok := privateV2CanonicalBinary(input.Nonce, 12, 12); !ok {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid nonce"))
		return
	}
	ciphertext, ok := privateV2CanonicalBinary(input.Ciphertext, 0, maxInferenceBodyBytes+16)
	if !ok || len(ciphertext) < 16 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid ciphertext"))
		return
	}
	lease, err := s.privateV2Leases().consume(input.LeaseID, input.RequestID, consumerID)
	if err != nil {
		status := http.StatusConflict
		if errors.Is(err, errPrivateV2LeaseExpired) {
			status = http.StatusGone
		}
		writeJSON(w, status, errorResponse("private_v2_lease_invalid", "private-v2 lease is invalid or already used"))
		return
	}
	if !s.keyModelAllowed(r.Context(), lease.RequestedModel) {
		writeJSON(w, http.StatusForbidden, errorResponse("model_not_allowed", "this API key is not allowed to use the leased model"))
		return
	}
	policy := s.resolveSelfRoutePolicy(r)
	routeMode, ownerBinding := privateV2RouteBinding(policy)
	if routeMode != lease.Transcript.RouteMode || ownerBinding != lease.Transcript.OwnerBinding {
		writeJSON(w, http.StatusConflict, errorResponse("private_v2_lease_invalid", "authenticated route policy changed after preflight"))
		return
	}
	if lease.RequestedMax <= 0 ||
		uint64(lease.RequestedMax) > protocol.PrivateV2MaxOutputTokens ||
		uint64(lease.RequestedMax) != lease.Transcript.RequestedMaxOutputTokens {
		writeJSON(w, http.StatusConflict, errorResponse("private_v2_lease_invalid", "lease output admission binding is invalid"))
		return
	}
	traits := registry.RequestTraits{RequiresPrivateV2: true}
	resolved, _, routeOK := s.registry.ResolveModelConstrainedWithTraits(
		lease.RequestedModel, nil, policy.ownerAccountID, policy.enabled, policy.prefer, traits)
	if !routeOK || resolved != lease.Transcript.Model {
		writeJSON(w, http.StatusConflict, errorResponse("private_v2_lease_invalid", "leased model route is no longer authorized"))
		return
	}
	privatePlaintextBytes := len(ciphertext) - 16
	routingPromptTokens := max(1, (privatePlaintextBytes+3)/4)
	tokenAdmission, admitted := s.applyTokenRateLimitWithAdmission(
		w, r, routingPromptTokens, lease.RequestedMax)
	if !admitted {
		return
	}
	if tokenAdmission.TracksOutput() &&
		tokenAdmission.AdmittedOutputTokens < lease.RequestedMax {
		writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limit_exceeded", "private-v2 output admission is below the transcript-bound maximum"))
		return
	}
	pr := &registry.PendingRequest{RequestID: lease.Transcript.RequestID, Model: lease.Transcript.Model,
		PublicModel: lease.RequestedModel, ConsumerKey: consumerID, KeyID: keyIDFromContext(r.Context()),
		KeyLimitMicroUSD:   keyLimitMicroFromContext(r.Context()),
		KeyLimitReset:      keyLimitResetFromContext(r.Context()),
		RequestedMaxTokens: lease.RequestedMax, Traits: traits,
		RequiresVision: lease.Transcript.RequiresVision,
		SelfRouteOnly:  policy.enabled, PreferOwner: policy.prefer,
		OwnerAccountID: policy.ownerAccountID, FreeSelfRoute: policy.enabled,
		ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:                   make(chan protocol.InferenceErrorMessage, 1),
		PrivateV2ChunkCh:          make(chan protocol.PrivateChunkV2Message, privateV2ChunkBuffer),
		PrivateV2SettledCh:        make(chan struct{}),
		PrivateV2DeliveryCh:       make(chan struct{}),
		PrivateV2PromptTokenBound: privatePlaintextBytes,
		PrivateV2OutputTokenBound: lease.RequestedMax,
		Timing:                    &registry.RequestTiming{ReceivedAt: time.Now()},
		EstimatedPromptTokens:     routingPromptTokens, TokenAdmission: tokenAdmission,
	}
	provider, err := s.registry.ReservePrivateV2Provider(lease.Provider.ProviderID, lease.Transcript.Model, pr, lease.Provider)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("provider_unavailable", "leased private-v2 provider is unavailable"))
		return
	}
	reserved, serviceReservation, handled := s.reserveInferenceBalance(
		w, r, map[string]any{"model": pr.Model}, balanceReservationParams{
			model: pr.Model, publicModel: pr.PublicModel,
			billingPromptTokens:   privatePlaintextBytes,
			estimatedPromptTokens: routingPromptTokens,
			requestedMaxTokens:    pr.RequestedMaxTokens, stream: lease.Stream,
			requiresVision: lease.Transcript.RequiresVision, policy: policy,
		})
	if handled {
		s.privateV2EarlyCleanup(provider, pr, "private-v2-reservation-failed")
		return
	}
	pr.ReservedMicroUSD = reserved
	pr.BaseReservedMicroUSD = reserved
	pr.ServiceReservation = serviceReservation
	if s.billing != nil && !policy.enabled {
		if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
			s.privateV2EarlyCleanup(provider, pr, "private-v2-provider-reservation-failed")
			writeJSON(w, http.StatusPaymentRequired, errorResponse("insufficient_balance", "insufficient balance"))
			return
		}
	}

	wire := protocol.PrivateRequestV2Message{
		Type: protocol.TypePrivateRequestV2, Version: privateV2Version,
		LeaseID: lease.Transcript.LeaseID, RequestID: lease.Transcript.RequestID,
		RouteID: lease.Transcript.RouteID, Model: lease.Transcript.Model,
		Endpoint: lease.Transcript.Endpoint, Stream: lease.Stream, Deadline: lease.Transcript.Deadline,
		TranscriptDigest:         rawBase64URL.EncodeToString(lease.TranscriptHash[:]),
		ProcessCertificateDigest: lease.Transcript.ProcessCertificateDigest,
		ReleaseBinaryHash:        lease.Transcript.ReleaseBinaryHash,
		ModelManifestHash:        lease.Transcript.ModelManifestHash,
		ReleaseGeneration:        lease.Transcript.ReleaseGeneration,
		ModelGeneration:          lease.Transcript.ModelGeneration,
		RequestedMaxOutputTokens: lease.Transcript.RequestedMaxOutputTokens,
		RequiresVision:           lease.Transcript.RequiresVision,
		RouteMode:                lease.Transcript.RouteMode, OwnerBinding: lease.Transcript.OwnerBinding,
		KDFSalt:         rawBase64URL.EncodeToString(lease.KDFSalt[:]),
		ClientPublicKey: input.ClientPublicKey, Nonce: input.Nonce, Ciphertext: input.Ciphertext,
	}
	frame, err := json.Marshal(wire)
	if err != nil {
		s.privateV2EarlyCleanup(provider, pr, "private-v2-marshal-failed")
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to dispatch request"))
		return
	}
	if err := provider.WriteText(r.Context(), frame); err != nil {
		s.privateV2EarlyCleanup(provider, pr, "private-v2-send-failed")
		writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "private-v2 provider unavailable before encrypted response"))
		return
	}
	if lease.Stream {
		s.relayPrivateV2Stream(w, r, provider, pr)
		return
	}
	s.relayPrivateV2NonStream(w, r, provider, pr)
}

func (s *Server) cancelPrivateV2Relay(provider *registry.Provider, pr *registry.PendingRequest, reason string) {
	if pr == nil {
		return
	}
	if pr.ContentCommittedSafe() {
		s.holdForSettlement(pr)
		s.cancelDispatch(provider, pr)
		waitPrivateV2Settlement(pr)
		return
	}
	s.sendProviderCancel(provider, pr.RequestID)
	s.privateV2EarlyCleanup(provider, pr, reason)
	s.refundReservedBalance(pr, reason)
	pr.MarkReservationFinalized()
	pr.ResolvePrivateV2Delivery()
}

func waitPrivateV2Settlement(pr *registry.PendingRequest) {
	if pr != nil && pr.PrivateV2SettledCh != nil {
		<-pr.PrivateV2SettledCh
	}
}

func (s *Server) relayPrivateV2Stream(w http.ResponseWriter, r *http.Request, provider *registry.Provider, pr *registry.PendingRequest) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		s.privateV2EarlyCleanup(provider, pr, "private-v2-streaming-unsupported")
		pr.ResolvePrivateV2Delivery()
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "streaming unsupported"))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()
	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()
	for {
		select {
		case msg, open := <-pr.PrivateV2ChunkCh:
			if !open {
				if pr.ContentCommittedSafe() {
					waitPrivateV2Settlement(pr)
				} else {
					s.refundReservedBalance(pr, "private-v2-provider-disconnect")
					pr.MarkReservationFinalized()
					pr.ResolvePrivateV2Delivery()
					_, _ = fmt.Fprint(w, "event: error\ndata: {\"error\":\"provider unavailable before encrypted terminal response\"}\n\n")
					flusher.Flush()
				}
				return
			}
			encoded, _ := json.Marshal(msg)
			written, writeErr := fmt.Fprintf(w, "data: %s\n\n", encoded)
			flusher.Flush()
			if writeErr == nil && written > 0 {
				pr.MarkContentCommitted()
				pr.ResolvePrivateV2Delivery()
			} else if writeErr != nil {
				s.cancelPrivateV2Relay(provider, pr, "private-v2-client-write")
				return
			}
			if msg.Terminal {
				waitPrivateV2Settlement(pr)
				return
			}
		case <-r.Context().Done():
			s.cancelPrivateV2Relay(provider, pr, "private-v2-client-cancel")
			return
		case <-timer.C:
			s.cancelPrivateV2Relay(provider, pr, "private-v2-timeout")
			if !pr.ContentCommittedSafe() {
				_, _ = fmt.Fprint(w, "event: error\ndata: {\"error\":\"private-v2 provider response timed out\"}\n\n")
				flusher.Flush()
			}
			return
		}
	}
}

type privateV2NonStreamResponse struct {
	Version   string                           `json:"version"`
	RequestID string                           `json:"request_id"`
	Chunks    []protocol.PrivateChunkV2Message `json:"chunks"`
}

func (s *Server) relayPrivateV2NonStream(w http.ResponseWriter, r *http.Request, provider *registry.Provider, pr *registry.PendingRequest) {
	chunks := make([]protocol.PrivateChunkV2Message, 0, 16)
	totalBytes := 0
	timer := time.NewTimer(inferenceTimeout)
	defer timer.Stop()
	for {
		select {
		case msg, open := <-pr.PrivateV2ChunkCh:
			if !open {
				if pr.ContentCommittedSafe() {
					waitPrivateV2Settlement(pr)
				} else {
					s.refundReservedBalance(pr, "private-v2-provider-disconnect")
					pr.MarkReservationFinalized()
					pr.ResolvePrivateV2Delivery()
					writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "private-v2 provider unavailable before encrypted response"))
				}
				return
			}
			totalBytes += len(msg.Nonce) + len(msg.Ciphertext)
			if len(chunks) >= privateV2MaxResponseChunks || totalBytes > privateV2MaxResponseBytes {
				s.cancelPrivateV2Relay(provider, pr, "private-v2-nonstream-overflow")
				writeJSON(w, http.StatusBadGateway, errorResponse("provider_error", "private-v2 nonstream response exceeded relay bounds"))
				return
			}
			chunks = append(chunks, msg)
			if msg.Terminal {
				response := privateV2NonStreamResponse{
					Version: privateV2Version, RequestID: pr.RequestID, Chunks: chunks,
				}
				encoded, err := json.Marshal(response)
				if err != nil {
					s.cancelPrivateV2Relay(provider, pr, "private-v2-nonstream-marshal")
					writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to encode private-v2 response"))
					return
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusOK)
				if written, err := w.Write(encoded); err == nil && written > 0 {
					pr.MarkContentCommitted()
					pr.ResolvePrivateV2Delivery()
				} else {
					s.refundReservedBalance(pr, "private-v2-nonstream-client-write")
					pr.MarkReservationFinalized()
					pr.ResolvePrivateV2Delivery()
				}
				waitPrivateV2Settlement(pr)
				return
			}
		case <-r.Context().Done():
			s.cancelPrivateV2Relay(provider, pr, "private-v2-client-cancel")
			return
		case <-timer.C:
			s.cancelPrivateV2Relay(provider, pr, "private-v2-timeout")
			writeJSON(w, http.StatusGatewayTimeout, errorResponse("provider_error", "private-v2 provider response timed out"))
			return
		}
	}
}

func privacyTierHandler(tier string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Darkbloom-Privacy-Tier", tier)
		next(w, r)
	}
}
