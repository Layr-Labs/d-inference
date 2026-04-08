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
	"encoding/base64"
	"log/slog"
	"sort"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/attestation"
	"github.com/eigeninference/coordinator/internal/protocol"
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
	TrustSelfSigned TrustLevel = "self_signed" // Attestation signed by provider's own key
	TrustHardware   TrustLevel = "hardware"    // MDM + MDA + SE key bound to Apple-verified hardware
)

// PendingRequest is a channel-based handle for an in-flight inference request.
type PendingRequest struct {
	RequestID      string
	ProviderID     string
	Model          string
	ConsumerKey    string
	AcceptedCh     chan struct{}           // signalled when provider accepts request
	ChunkCh        chan string             // SSE data chunks
	CompleteCh     chan protocol.UsageInfo // closed after usage sent
	ErrorCh        chan protocol.InferenceErrorMessage
	SessionPrivKey *[32]byte // E2E session private key for decrypting responses
	SESignature    string    // SE signature over response hash
	ResponseHash   string    // SHA-256 of response data

	// STT transcription result (nil for inference requests)
	TranscriptionCh chan *protocol.TranscriptionCompleteMessage

	// Image generation result (nil for non-image requests)
	ImageGenerationCh chan *protocol.ImageGenerationCompleteMessage

	// ReservedMicroUSD is the balance atomically debited at pre-flight.
	// The post-inference charge adjusts for the difference between the
	// actual cost and this reservation, preventing billing race conditions.
	ReservedMicroUSD int64
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
	TrustLevel        TrustLevel             // attestation trust level
	MDAVerified       bool                   // true if Apple Device Attestation cert chain verified
	MDACertChain      [][]byte               // DER-encoded Apple MDA certificate chain (leaf first)
	MDAResult         *attestation.MDAResult // parsed OIDs from Apple cert
	ACMEVerified      bool                   // true if ACME device-attest-01 client cert verified (SE key proven)
	SEKeyBound        bool                   // true if SE key was bound to device via MDA nonce
	Status            ProviderStatus
	Conn              *websocket.Conn
	LastHeartbeat     time.Time
	Stats             protocol.HeartbeatStats

	// Account linkage (set when provider authenticates via device auth token)
	AccountID string // internal account ID (from device auth flow)

	// Benchmark data reported at registration
	PrefillTPS float64 // prefill tokens per second
	DecodeTPS  float64 // decode tokens per second

	// Warm model cache tracking
	WarmModels   []string // models currently loaded in provider's memory
	CurrentModel string   // model currently being served

	// Live system metrics from heartbeats
	SystemMetrics protocol.SystemMetrics

	// Reputation tracking
	Reputation Reputation

	// Version and runtime integrity verification
	Version         string `json:"version,omitempty"` // provider binary version (e.g. "0.2.31")
	RuntimeVerified bool   `json:"runtime_verified"`  // true if runtime hashes match the known-good manifest
	PythonHash      string `json:"python_hash,omitempty"`
	RuntimeHash     string `json:"runtime_hash,omitempty"`

	// Challenge-response verification state
	LastChallengeVerified time.Time // last successful challenge verification
	FailedChallenges      int       // consecutive failed challenges

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

// SetAttested updates attestation state (thread-safe).
func (p *Provider) SetAttested(attested bool, trust TrustLevel) {
	p.mu.Lock()
	p.Attested = attested
	p.TrustLevel = trust
	p.mu.Unlock()
}

// Mu returns the provider's mutex for external callers that need to read
// fields like Status atomically. Prefer dedicated getters where available.
func (p *Provider) Mu() *sync.Mutex {
	return &p.mu
}

// SetAttestationResult stores the parsed attestation result (thread-safe).
func (p *Provider) SetAttestationResult(result *attestation.VerificationResult) {
	p.mu.Lock()
	p.AttestationResult = result
	p.mu.Unlock()
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

	// modelCatalog maps active model IDs to their catalog metadata (including
	// expected weight hashes). When non-empty, only models in this map are
	// accepted from providers and routable by consumers. Updated via SetModelCatalog.
	modelCatalog map[string]CatalogEntry

	logger *slog.Logger
}

// New creates a new Registry.
func New(logger *slog.Logger) *Registry {
	return &Registry{
		providers:     make(map[string]*Provider),
		queue:         NewRequestQueue(10, 120*time.Second),
		MinTrustLevel: TrustHardware,
		logger:        logger,
	}
}

// TruncHash returns the first 16 chars of a hash string for logging.
func TruncHash(h string) string {
	if len(h) > 16 {
		return h[:16] + "..."
	}
	return h
}

// CatalogEntry holds metadata about an active model in the catalog.
type CatalogEntry struct {
	ID         string
	WeightHash string // expected SHA-256 weight fingerprint (empty = not enforced)
}

// SetModelCatalog updates the set of active models. Only models in this
// set will be accepted from providers during registration and routable to
// consumers. Pass nil or empty to disable catalog filtering.
func (r *Registry) SetModelCatalog(entries []CatalogEntry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(entries) == 0 {
		r.modelCatalog = nil
		return
	}
	catalog := make(map[string]CatalogEntry, len(entries))
	for _, e := range entries {
		catalog[e.ID] = e
	}
	r.modelCatalog = catalog
}

// IsModelInCatalog returns true if the model is in the active catalog,
// or if no catalog is configured (all models allowed).
func (r *Registry) IsModelInCatalog(model string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if len(r.modelCatalog) == 0 {
		return true
	}
	_, ok := r.modelCatalog[model]
	return ok
}

// CatalogWeightHash returns the expected weight hash for a model, or empty
// string if not set or not in catalog.
func (r *Registry) CatalogWeightHash(model string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if e, ok := r.modelCatalog[model]; ok {
		return e.WeightHash
	}
	return ""
}

// trustMeetsMinimum returns true if the given trust level meets the minimum.
func (r *Registry) trustMeetsMinimum(level TrustLevel) bool {
	return trustRank(level) >= trustRank(r.MinTrustLevel)
}

// Queue returns the registry's request queue.
func (r *Registry) Queue() *RequestQueue {
	return r.queue
}

// SetQueue replaces the registry's request queue. This is useful for tests
// that need a larger queue capacity than the default.
func (r *Registry) SetQueue(q *RequestQueue) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.queue = q
}

// Register adds a new provider to the registry, returning its assigned ID.
// If a model catalog is configured, only models in the catalog are kept.
func (r *Registry) Register(id string, conn *websocket.Conn, msg *protocol.RegisterMessage) *Provider {
	// Filter models against the catalog before storing.
	models := msg.Models
	r.mu.RLock()
	catalog := r.modelCatalog
	r.mu.RUnlock()
	if len(catalog) > 0 {
		filtered := make([]protocol.ModelInfo, 0, len(models))
		for _, m := range models {
			entry, inCatalog := catalog[m.ID]
			if !inCatalog {
				r.logger.Debug("provider model not in catalog, skipping",
					"provider_id", id, "model", m.ID)
				continue
			}
			// Verify weight hash if the catalog has an expected hash.
			if entry.WeightHash != "" && m.WeightHash != "" && m.WeightHash != entry.WeightHash {
				r.logger.Warn("provider model weight hash mismatch, rejecting model",
					"provider_id", id, "model", m.ID,
					"expected", TruncHash(entry.WeightHash),
					"got", TruncHash(m.WeightHash),
				)
				continue
			}
			filtered = append(filtered, m)
		}
		models = filtered
	}

	// Validate X25519 public key if provided.
	// Reject invalid keys at registration rather than failing at encryption time.
	pubKey := msg.PublicKey
	if pubKey != "" {
		decoded, err := base64.StdEncoding.DecodeString(pubKey)
		if err != nil || len(decoded) != 32 {
			r.logger.Warn("provider public key invalid, clearing",
				"provider_id", id,
				"error", "must be 32-byte base64-encoded X25519 key",
			)
			pubKey = "" // clear so provider can register but won't receive encrypted requests
		}
	}

	p := &Provider{
		ID:              id,
		Hardware:        msg.Hardware,
		Models:          models,
		Backend:         msg.Backend,
		PublicKey:       pubKey,
		WalletAddress:   msg.WalletAddress,
		PrefillTPS:      msg.PrefillTPS,
		DecodeTPS:       msg.DecodeTPS,
		TrustLevel:      TrustNone,
		RuntimeVerified: true, // default to verified; API layer sets false when manifest check fails
		Status:          StatusOnline,
		Conn:            conn,
		LastHeartbeat:   time.Now(),
		Reputation:      NewReputation(),
		pendingReqs:     make(map[string]*PendingRequest),
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

// DisconnectDuplicatesBySerial disconnects all providers that share the same
// serial number as the given provider, except the given provider itself.
// This prevents multiple WebSocket connections from the same physical machine
// from competing for the same vllm-mlx backend on localhost.
func (r *Registry) DisconnectDuplicatesBySerial(keepID string, serial string) {
	if serial == "" {
		return
	}

	var toEvict []string

	r.mu.RLock()
	for id, p := range r.providers {
		if id == keepID {
			continue
		}
		if p.AttestationResult != nil && p.AttestationResult.SerialNumber == serial {
			toEvict = append(toEvict, id)
		}
	}
	r.mu.RUnlock()

	for _, id := range toEvict {
		r.mu.RLock()
		p := r.providers[id]
		r.mu.RUnlock()

		r.logger.Warn("evicting duplicate provider from same device",
			"evicted_id", id,
			"kept_id", keepID,
			"serial", serial,
		)
		r.Disconnect(id)

		if p != nil && p.Conn != nil {
			p.Conn.Close(websocket.StatusNormalClosure, "replaced by new connection from same device")
		}
	}
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
	p.SystemMetrics = msg.SystemMetrics
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

// SetTrustLevel updates a provider's trust level (thread-safe).
func (r *Registry) SetTrustLevel(providerID string, level TrustLevel) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}
	p.mu.Lock()
	p.TrustLevel = level
	p.mu.Unlock()
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

	// Drain queued requests — a newly verified provider can serve them.
	if r.queue != nil && p.PendingCount() < MaxConcurrentRequests {
		for _, m := range p.Models {
			if r.queue.TryAssign(m.ID, p) {
				break
			}
		}
	}
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

// MaxConcurrentRequests is the maximum number of simultaneous inference
// requests a provider can handle. The AdaptiveEngine queues requests at
// the provider level for maximum single-request throughput. The coordinator
// uses this + the load factor in scoring to naturally prefer idle providers
// while still allowing queuing when all providers are busy.
const MaxConcurrentRequests = 4

// ScoreProvider calculates a routing score for a provider.
// Higher scores indicate better routing candidates.
// Score = (1 - load) * decode_tps * trust_multiplier * reputation * warm_bonus
func ScoreProvider(p *Provider, model string) float64 {
	// Providers that have not passed runtime integrity verification score 0
	// and should never be selected for routing.
	p.mu.Lock()
	runtimeVerified := p.RuntimeVerified
	p.mu.Unlock()
	if !runtimeVerified {
		return 0
	}

	// Load: gradient from 0.0 (idle) to 1.0 (at max concurrency).
	// Providers with fewer in-flight requests score higher.
	pending := float64(p.PendingCount())
	load := pending / float64(MaxConcurrentRequests)
	if load > 1.0 {
		load = 1.0
	}

	// Snapshot mutable fields under lock. These are written by Heartbeat
	// and SetTrustLevel from other goroutines.
	p.mu.Lock()
	decodeTPS := p.DecodeTPS
	trustLevel := p.TrustLevel
	warmModels := append([]string{}, p.WarmModels...)
	currentModel := p.CurrentModel
	sysMetrics := p.SystemMetrics
	repScore := p.Reputation.Score()
	p.mu.Unlock()

	// Base decode TPS — use 1.0 as minimum to avoid zero scores
	if decodeTPS <= 0 {
		decodeTPS = 1.0
	}

	trustMul := TrustMultiplier(trustLevel)

	// Warm model bonus: 1.5x if the model is already warm, 1.0x otherwise
	warmBonus := 1.0
	for _, wm := range warmModels {
		if wm == model {
			warmBonus = 1.5
			break
		}
	}
	if currentModel == model {
		warmBonus = 1.5
	}

	// Health factor from live system metrics
	m := sysMetrics

	// Memory pressure: linear penalty. At 0.9 -> factor 0.1
	memFactor := 1.0 - m.MemoryPressure
	if memFactor < 0.1 {
		memFactor = 0.1
	}

	// CPU usage: gentle penalty (max 50% reduction at full load)
	cpuFactor := 1.0 - (m.CPUUsage * 0.5)

	// Thermal: step penalties
	thermalFactor := 1.0
	switch m.ThermalState {
	case "fair":
		thermalFactor = 0.8
	case "serious":
		thermalFactor = 0.4
	case "critical":
		thermalFactor = 0.0
	}

	healthFactor := memFactor * cpuFactor * thermalFactor

	return (1.0 - load) * decodeTPS * trustMul * repScore * warmBonus * healthFactor
}

// FindProvider selects an available provider for the given model using
// intelligent scoring based on benchmark data, trust level, reputation,
// and warm model cache. Picks the highest-scoring provider that has
// concurrency headroom (pending requests < MaxConcurrentRequests).
func (r *Registry) FindProvider(model string) *Provider {
	return r.FindProviderWithTrust(model, "")
}

// FindProviderWithTrust selects a provider with an optional per-request
// minimum trust level. If minTrust is empty, the registry's default
// MinTrustLevel is used. Consumers can request a specific trust level
// (e.g. hardware) to filter providers.
func (r *Registry) FindProviderWithTrust(model string, minTrust TrustLevel) *Provider {
	r.mu.Lock()
	defer r.mu.Unlock()

	// Determine effective minimum: max of registry default and per-request
	effectiveMin := r.MinTrustLevel
	if minTrust != "" && trustRank(minTrust) > trustRank(effectiveMin) {
		effectiveMin = minTrust
	}

	// Challenge staleness threshold: providers must have passed a
	// challenge within the last interval + grace period. A provider
	// that reconnects without passing the immediate challenge (or whose
	// last challenge is too old) won't be routed requests.
	challengeMaxAge := 3*time.Minute + 30*time.Second
	now := time.Now()

	var candidates []*Provider
	for _, p := range r.providers {
		// Snapshot mutable fields under the provider lock.
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		lastChallenge := p.LastChallengeVerified
		runtimeVerified := p.RuntimeVerified
		p.mu.Unlock()

		// Skip offline/untrusted providers
		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		if trustRank(trust) < trustRank(effectiveMin) {
			continue
		}
		// Skip providers whose runtime integrity has not been verified.
		if !runtimeVerified {
			continue
		}
		// Skip providers that haven't passed a recent challenge.
		if lastChallenge.IsZero() || now.Sub(lastChallenge) > challengeMaxAge {
			continue
		}
		// Skip providers at max concurrency
		if p.PendingCount() >= MaxConcurrentRequests {
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
	// Providers with fewer pending requests score higher due to load factor.
	sort.Slice(candidates, func(i, j int) bool {
		return ScoreProvider(candidates[i], model) > ScoreProvider(candidates[j], model)
	})

	selected := candidates[0]
	selected.mu.Lock()
	selected.Status = StatusServing
	selected.mu.Unlock()

	return selected
}

// SetProviderIdle updates a provider's status after a request completes.
// If pending count reaches zero, status goes back to online. If there are
// queued requests and the provider has concurrency headroom, the next
// queued request is assigned immediately.
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

	// Check if there are queued requests and this provider has headroom.
	hasCap := p.PendingCount() < MaxConcurrentRequests
	p.mu.Lock()
	trust := p.TrustLevel
	p.mu.Unlock()
	if r.queue != nil && hasCap && r.trustMeetsMinimum(trust) {
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

	type modelAgg struct {
		modelType     string
		quantization  string
		count         int
		attestedCount int
		highestTrust  TrustLevel
		secureEnclave bool
		sipEnabled    bool
		secureBoot    bool
	}

	// Aggregate by model ID only — consumers request by ID, so providers
	// offering the same model ID should be counted together regardless of
	// minor metadata differences.
	agg := make(map[string]*modelAgg)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		attested := p.Attested
		attestResult := p.AttestationResult
		p.mu.Unlock()

		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		if !r.trustMeetsMinimum(trust) {
			continue
		}
		for _, m := range p.Models {
			k := m.ID
			a, ok := agg[k]
			if !ok {
				a = &modelAgg{
					modelType:    m.ModelType,
					quantization: m.Quantization,
					highestTrust: TrustNone,
				}
				agg[k] = a
			}
			a.count++

			// Update highest trust level
			if trustRank(trust) > trustRank(a.highestTrust) {
				a.highestTrust = trust
			}

			if attested && attestResult != nil {
				a.attestedCount++
				a.secureEnclave = a.secureEnclave || attestResult.SecureEnclaveAvailable
				a.sipEnabled = a.sipEnabled || attestResult.SIPEnabled
				a.secureBoot = a.secureBoot || attestResult.SecureBootEnabled
			}
		}
	}

	models := make([]AggregateModel, 0, len(agg))
	for k, a := range agg {
		am := AggregateModel{
			ID:                k,
			ModelType:         a.modelType,
			Quantization:      a.quantization,
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
// Returns -1 for unknown/invalid trust levels.
func trustRank(t TrustLevel) int {
	switch t {
	case TrustHardware:
		return 2
	case TrustSelfSigned:
		return 1
	case TrustNone:
		return 0
	default:
		return -1
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

// ForEachProvider iterates over all registered providers (read lock held).
func (r *Registry) ForEachProvider(fn func(p *Provider)) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		fn(p)
	}
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
