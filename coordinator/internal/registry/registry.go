// Package registry manages the set of connected provider agents, their
// capabilities, and routes inference requests to appropriate providers.
//
// The registry is the coordinator's in-memory view of the provider fleet.
// It tracks each provider's hardware, available models, attestation status,
// trust level, and operational state (online/serving/offline/untrusted).
//
// Routing uses round-robin among idle providers that serve the requested
// model. Providers that fail too many attestation challenges are marked
// as untrusted and excluded from routing. Stale providers (no heartbeat
// within the timeout) are evicted by a background goroutine.
//
// Trust levels:
//   - none: Provider did not include an attestation blob
//   - self_signed: Provider's attestation was signed by its own SE key
//   - hardware: MDA certificate chain verified (future, requires Apple
//     Business Manager enrollment)
package registry

import (
	"context"
	"log/slog"
	"sort"
	"sync"
	"time"

	"github.com/dginf/coordinator/internal/attestation"
	"github.com/dginf/coordinator/internal/protocol"
	"nhooyr.io/websocket"
)

// ProviderStatus represents the operational state of a provider.
type ProviderStatus string

const (
	StatusOnline    ProviderStatus = "online"
	StatusServing   ProviderStatus = "serving"
	StatusOffline   ProviderStatus = "offline"
	StatusUntrusted ProviderStatus = "untrusted"
)

// TrustLevel represents the attestation trust level of a provider.
type TrustLevel string

const (
	TrustNone       TrustLevel = "none"        // No attestation provided
	TrustSelfSigned TrustLevel = "self_signed"  // Attestation signed by provider's own key (current)
	TrustHardware   TrustLevel = "hardware"     // MDA certificate chain verified (future)
)

// PendingRequest is a channel-based handle for an in-flight inference request.
type PendingRequest struct {
	RequestID      string
	ProviderID     string
	Model          string
	ConsumerKey    string
	ChunkCh        chan string             // SSE data chunks
	CompleteCh     chan protocol.UsageInfo  // closed after usage sent
	ErrorCh        chan protocol.InferenceErrorMessage
	SessionPrivKey *[32]byte               // E2E session private key for decrypting responses
}

// Provider represents a connected provider agent.
type Provider struct {
	ID                string
	Hardware          protocol.Hardware
	Models            []protocol.ModelInfo
	Backend           string
	PublicKey         string // base64-encoded X25519 public key for E2E encryption
	WalletAddress     string // Ethereum-format hex address for Tempo payouts
	Attested          bool   // true if attestation was verified successfully
	AttestationResult *attestation.VerificationResult
	TrustLevel        TrustLevel // attestation trust level
	MDAVerified       bool       // true if Apple Device Attestation cert chain verified
	Status            ProviderStatus
	Conn              *websocket.Conn
	LastHeartbeat     time.Time
	Stats             protocol.HeartbeatStats

	// Benchmark data reported at registration
	PrefillTPS float64 // prefill tokens per second
	DecodeTPS  float64 // decode tokens per second

	// Warm model cache tracking
	WarmModels   []string // models currently loaded in provider's memory
	CurrentModel string   // model currently being served

	// Reputation tracking
	Reputation Reputation

	// Challenge-response verification state
	LastChallengeVerified time.Time // last successful challenge verification
	FailedChallenges     int       // consecutive failed challenges

	mu          sync.Mutex
	pendingReqs map[string]*PendingRequest
}

// AddPending registers a pending request on this provider.
func (p *Provider) AddPending(pr *PendingRequest) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.pendingReqs[pr.RequestID] = pr
}

// RemovePending removes and returns a pending request.
func (p *Provider) RemovePending(requestID string) *PendingRequest {
	p.mu.Lock()
	defer p.mu.Unlock()
	pr := p.pendingReqs[requestID]
	delete(p.pendingReqs, requestID)
	return pr
}

// GetPending retrieves a pending request without removing it.
func (p *Provider) GetPending(requestID string) *PendingRequest {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingReqs[requestID]
}

// pendingCount returns the number of in-flight requests.
// Caller must hold p.mu.
func (p *Provider) pendingCount() int {
	return len(p.pendingReqs)
}

// PendingCount returns the number of in-flight requests (thread-safe).
func (p *Provider) PendingCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingCount()
}

// Registry holds all connected providers and provides routing.
type Registry struct {
	mu        sync.RWMutex
	providers map[string]*Provider

	// queue manages requests waiting for a provider to become available.
	queue *RequestQueue

	// MinTrustLevel is the minimum trust level required for routing.
	// Defaults to TrustHardware. Set to TrustNone for testing.
	MinTrustLevel TrustLevel

	logger *slog.Logger
}

// New creates a new Registry.
func New(logger *slog.Logger) *Registry {
	return &Registry{
		providers:     make(map[string]*Provider),
		queue:         NewRequestQueue(10, 30*time.Second),
		MinTrustLevel: TrustHardware,
		logger:        logger,
	}
}

// trustMeetsMinimum returns true if the given trust level meets the minimum.
func (r *Registry) trustMeetsMinimum(level TrustLevel) bool {
	switch r.MinTrustLevel {
	case TrustNone:
		return true
	case TrustSelfSigned:
		return level == TrustSelfSigned || level == TrustHardware
	default: // TrustHardware
		return level == TrustHardware
	}
}

// Queue returns the registry's request queue.
func (r *Registry) Queue() *RequestQueue {
	return r.queue
}

// Register adds a new provider to the registry, returning its assigned ID.
func (r *Registry) Register(id string, conn *websocket.Conn, msg *protocol.RegisterMessage) *Provider {
	p := &Provider{
		ID:            id,
		Hardware:      msg.Hardware,
		Models:        msg.Models,
		Backend:       msg.Backend,
		PublicKey:     msg.PublicKey,
		WalletAddress: msg.WalletAddress,
		PrefillTPS:    msg.PrefillTPS,
		DecodeTPS:     msg.DecodeTPS,
		TrustLevel:    TrustNone,
		Status:        StatusOnline,
		Conn:          conn,
		LastHeartbeat: time.Now(),
		Reputation:    NewReputation(),
		pendingReqs:   make(map[string]*PendingRequest),
	}

	r.mu.Lock()
	r.providers[id] = p
	r.mu.Unlock()

	r.logger.Info("provider registered",
		"provider_id", id,
		"chip", msg.Hardware.ChipName,
		"memory_gb", msg.Hardware.MemoryGB,
		"models", len(msg.Models),
		"backend", msg.Backend,
		"prefill_tps", msg.PrefillTPS,
		"decode_tps", msg.DecodeTPS,
	)

	return p
}

// Heartbeat updates the provider's status and stats.
func (r *Registry) Heartbeat(id string, msg *protocol.HeartbeatMessage) {
	r.mu.RLock()
	p, ok := r.providers[id]
	r.mu.RUnlock()
	if !ok {
		r.logger.Warn("heartbeat from unknown provider", "provider_id", id)
		return
	}

	p.mu.Lock()
	p.LastHeartbeat = time.Now()
	p.Stats = msg.Stats
	// Update warm models from heartbeat
	if len(msg.WarmModels) > 0 {
		p.WarmModels = msg.WarmModels
	}
	if msg.ActiveModel != nil {
		p.CurrentModel = *msg.ActiveModel
	}
	// Only update status from heartbeat if provider is not actively serving
	// (serving status is managed by request lifecycle).
	if p.Status != StatusServing || msg.Status == "idle" {
		switch msg.Status {
		case "idle":
			p.Status = StatusOnline
		case "serving":
			p.Status = StatusServing
		}
	}
	p.mu.Unlock()
}

// Disconnect removes a provider from the registry and cleans up pending requests.
func (r *Registry) Disconnect(id string) {
	r.mu.Lock()
	p, ok := r.providers[id]
	if ok {
		delete(r.providers, id)
	}
	r.mu.Unlock()

	if !ok {
		return
	}

	// Close all pending request channels so consumers get errors.
	p.mu.Lock()
	for reqID, pr := range p.pendingReqs {
		pr.ErrorCh <- protocol.InferenceErrorMessage{
			Type:       protocol.TypeInferenceError,
			RequestID:  reqID,
			Error:      "provider disconnected",
			StatusCode: 502,
		}
		close(pr.ChunkCh)
		close(pr.CompleteCh)
		close(pr.ErrorCh)
	}
	p.pendingReqs = make(map[string]*PendingRequest)
	p.mu.Unlock()

	r.logger.Info("provider disconnected", "provider_id", id)
}

// GetProvider returns a provider by ID, or nil if not found.
func (r *Registry) GetProvider(id string) *Provider {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.providers[id]
}

// MarkUntrusted sets a provider's status to untrusted, preventing it from
// receiving new jobs. This is called when a provider fails too many
// challenge-response verifications.
func (r *Registry) MarkUntrusted(providerID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Status = StatusUntrusted
	p.mu.Unlock()

	r.logger.Warn("provider marked as untrusted",
		"provider_id", providerID,
		"failed_challenges", p.FailedChallenges,
	)
}

// RecordChallengeSuccess records a successful challenge-response verification.
func (r *Registry) RecordChallengeSuccess(providerID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.LastChallengeVerified = time.Now()
	p.FailedChallenges = 0
	p.mu.Unlock()
}

// RecordChallengeFailure records a failed challenge-response. Returns the
// new consecutive failure count.
func (r *Registry) RecordChallengeFailure(providerID string) int {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return 0
	}

	p.mu.Lock()
	p.FailedChallenges++
	count := p.FailedChallenges
	p.mu.Unlock()

	return count
}

// TrustMultiplier returns the trust multiplier for routing score calculation.
func TrustMultiplier(t TrustLevel) float64 {
	switch t {
	case TrustHardware:
		return 1.0
	case TrustSelfSigned:
		return 0.8
	default:
		return 0.5
	}
}

// ScoreProvider calculates a routing score for a provider.
// Higher scores indicate better routing candidates.
// Score = (1 - load) * decode_tps * trust_multiplier * reputation * warm_bonus
func ScoreProvider(p *Provider, model string) float64 {
	// Load: 0.0 for idle, 1.0 for serving
	var load float64
	if p.Status == StatusServing {
		load = 1.0
	}

	// Base decode TPS — use 1.0 as minimum to avoid zero scores
	decodeTPS := p.DecodeTPS
	if decodeTPS <= 0 {
		decodeTPS = 1.0
	}

	trustMul := TrustMultiplier(p.TrustLevel)

	// Reputation factor (0.0 to 1.0)
	repScore := p.Reputation.Score()

	// Warm model bonus: 1.5x if the model is already warm, 1.0x otherwise
	warmBonus := 1.0
	for _, wm := range p.WarmModels {
		if wm == model {
			warmBonus = 1.5
			break
		}
	}
	if p.CurrentModel == model {
		warmBonus = 1.5
	}

	return (1.0 - load) * decodeTPS * trustMul * repScore * warmBonus
}

// FindProvider selects an available provider for the given model using
// intelligent scoring based on benchmark data, trust level, reputation,
// and warm model cache. Picks the highest-scoring idle provider.
// Only providers with hardware trust (MDM-verified) are eligible.
func (r *Registry) FindProvider(model string) *Provider {
	r.mu.Lock()
	defer r.mu.Unlock()

	var candidates []*Provider
	for _, p := range r.providers {
		if p.Status != StatusOnline {
			continue
		}
		if !r.trustMeetsMinimum(p.TrustLevel) {
			continue
		}
		for _, m := range p.Models {
			if m.ID == model {
				candidates = append(candidates, p)
				break
			}
		}
	}

	if len(candidates) == 0 {
		return nil
	}

	// Sort candidates by score descending (highest score first).
	sort.Slice(candidates, func(i, j int) bool {
		return ScoreProvider(candidates[i], model) > ScoreProvider(candidates[j], model)
	})

	selected := candidates[0]
	selected.Status = StatusServing

	return selected
}

// SetProviderIdle marks a provider as idle (available for new requests).
// If there are queued requests for any model this provider serves, the
// first matching queued request is assigned to this provider.
func (r *Registry) SetProviderIdle(id string) {
	r.mu.RLock()
	p, ok := r.providers[id]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	if p.pendingCount() == 0 {
		p.Status = StatusOnline
	}
	p.mu.Unlock()

	// Check if there are queued requests for any model this provider serves.
	if r.queue != nil && p.Status == StatusOnline && r.trustMeetsMinimum(p.TrustLevel) {
		for _, m := range p.Models {
			if r.queue.TryAssign(m.ID, p) {
				break
			}
		}
	}
}

// AttestationSummary provides aggregate attestation status for a model's providers.
type AttestationSummary struct {
	SecureEnclave bool `json:"secure_enclave"`
	SIPEnabled    bool `json:"sip_enabled"`
	SecureBoot    bool `json:"secure_boot"`
}

// AggregateModel is a deduplicated model entry for the /v1/models endpoint.
type AggregateModel struct {
	ID                string              `json:"id"`
	ModelType         string              `json:"model_type"`
	Quantization      string              `json:"quantization"`
	Providers         int                 `json:"providers"`          // number of providers offering this model
	AttestedProviders int                 `json:"attested_providers"` // number of attested providers
	TrustLevel        TrustLevel          `json:"trust_level"`        // highest trust level among providers
	Attestation       *AttestationSummary `json:"attestation,omitempty"`
}

// ListModels returns deduplicated models from all online providers.
func (r *Registry) ListModels() []AggregateModel {
	r.mu.RLock()
	defer r.mu.RUnlock()

	type modelKey struct {
		id           string
		modelType    string
		quantization string
	}

	type modelAgg struct {
		count             int
		attestedCount     int
		highestTrust      TrustLevel
		secureEnclave     bool
		sipEnabled        bool
		secureBoot        bool
	}

	agg := make(map[modelKey]*modelAgg)
	for _, p := range r.providers {
		if p.Status == StatusOffline || p.Status == StatusUntrusted {
			continue
		}
		if !r.trustMeetsMinimum(p.TrustLevel) {
			continue
		}
		for _, m := range p.Models {
			k := modelKey{id: m.ID, modelType: m.ModelType, quantization: m.Quantization}
			a, ok := agg[k]
			if !ok {
				a = &modelAgg{highestTrust: TrustNone}
				agg[k] = a
			}
			a.count++

			// Update highest trust level
			if trustRank(p.TrustLevel) > trustRank(a.highestTrust) {
				a.highestTrust = p.TrustLevel
			}

			if p.Attested && p.AttestationResult != nil {
				a.attestedCount++
				a.secureEnclave = a.secureEnclave || p.AttestationResult.SecureEnclaveAvailable
				a.sipEnabled = a.sipEnabled || p.AttestationResult.SIPEnabled
				a.secureBoot = a.secureBoot || p.AttestationResult.SecureBootEnabled
			}
		}
	}

	models := make([]AggregateModel, 0, len(agg))
	for k, a := range agg {
		am := AggregateModel{
			ID:                k.id,
			ModelType:         k.modelType,
			Quantization:      k.quantization,
			Providers:         a.count,
			AttestedProviders: a.attestedCount,
			TrustLevel:        a.highestTrust,
		}
		if a.attestedCount > 0 {
			am.Attestation = &AttestationSummary{
				SecureEnclave: a.secureEnclave,
				SIPEnabled:    a.sipEnabled,
				SecureBoot:    a.secureBoot,
			}
		}
		models = append(models, am)
	}

	return models
}

// trustRank returns a numeric rank for trust levels (higher = more trusted).
func trustRank(t TrustLevel) int {
	switch t {
	case TrustHardware:
		return 2
	case TrustSelfSigned:
		return 1
	default:
		return 0
	}
}

// RecordJobSuccess records a successful job completion for the provider's reputation.
func (r *Registry) RecordJobSuccess(providerID string, responseTime time.Duration) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Reputation.RecordJobSuccess(responseTime)
	p.mu.Unlock()
}

// RecordJobFailure records a failed job for the provider's reputation.
func (r *Registry) RecordJobFailure(providerID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Reputation.RecordJobFailure()
	p.mu.Unlock()
}

// ProviderCount returns the number of registered providers.
func (r *Registry) ProviderCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.providers)
}

// ProviderIDs returns the IDs of all registered providers.
func (r *Registry) ProviderIDs() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ids := make([]string, 0, len(r.providers))
	for id := range r.providers {
		ids = append(ids, id)
	}
	return ids
}

// StartEvictionLoop starts a background goroutine that removes providers
// that haven't sent a heartbeat within the given timeout. It stops when
// the context is cancelled.
func (r *Registry) StartEvictionLoop(ctx context.Context, timeout time.Duration) {
	ticker := time.NewTicker(timeout / 3)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r.evictStale(timeout)
			}
		}
	}()
}

func (r *Registry) evictStale(timeout time.Duration) {
	r.mu.RLock()
	var stale []string
	now := time.Now()
	for id, p := range r.providers {
		if now.Sub(p.LastHeartbeat) > timeout {
			stale = append(stale, id)
		}
	}
	r.mu.RUnlock()

	for _, id := range stale {
		r.logger.Warn("evicting stale provider", "provider_id", id, "timeout", timeout)
		r.Disconnect(id)
	}
}
