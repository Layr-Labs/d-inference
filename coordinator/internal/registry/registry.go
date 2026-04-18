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
	"encoding/json"
	"log/slog"
	"math"
	"math/rand"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/attestation"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/store"
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
	RequestID   string
	ProviderID  string
	Model       string
	ConsumerKey string
	// EstimatedPromptTokens is a coordinator-side heuristic used only for
	// routing and queue admission. It does not need tokenizer-perfect accuracy.
	EstimatedPromptTokens int
	// RequestedMaxTokens is the consumer's requested output budget (or a
	// sensible default when omitted). It is used for backlog estimation.
	RequestedMaxTokens int
	AcceptedCh         chan struct{}           // signalled when provider accepts request
	ChunkCh            chan string             // SSE data chunks
	CompleteCh         chan protocol.UsageInfo // closed after usage sent
	ErrorCh            chan protocol.InferenceErrorMessage
	SessionPrivKey     *[32]byte // E2E session private key for decrypting responses
	SESignature        string    // SE signature over response hash
	ResponseHash       string    // SHA-256 of response data

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
	Stats             protocol.HeartbeatStats // lifetime counters shown to users
	lastSessionStats  protocol.HeartbeatStats // raw counters from the current provider process

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

	// Live backend capacity from heartbeats (nil for providers without capacity reporting)
	BackendCapacity *protocol.BackendCapacity

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
	p.addPendingLocked(pr)
}

// addPendingLocked registers a pending request. Caller must hold p.mu.
func (p *Provider) addPendingLocked(pr *PendingRequest) {
	p.pendingReqs[pr.RequestID] = pr
}

// RemovePending removes and returns a pending request.
func (p *Provider) RemovePending(requestID string) *PendingRequest {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.removePendingLocked(requestID)
}

// removePendingLocked removes and returns a pending request. Caller must hold p.mu.
func (p *Provider) removePendingLocked(requestID string) *PendingRequest {
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
// Note: persistence is handled by the Registry methods that call this,
// via persistProvider() after attestation verification completes.
func (p *Provider) SetAttested(attested bool, trust TrustLevel) {
	p.mu.Lock()
	p.Attested = attested
	p.TrustLevel = trust
	p.mu.Unlock()
}

// SetLastChallengeVerified updates the challenge timestamp (thread-safe).
func (p *Provider) SetLastChallengeVerified(t time.Time) {
	p.mu.Lock()
	p.LastChallengeVerified = t
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

// MaxConcurrency returns the dynamic max concurrent request limit.
// Uses hardware-based estimation when backend capacity is reported.
// Falls back to DefaultMaxConcurrent for providers without capacity reporting.
func (p *Provider) MaxConcurrency() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.maxConcurrency()
}

// maxConcurrency is the lock-free version (caller must hold p.mu).
func (p *Provider) maxConcurrency() int {
	if p.BackendCapacity == nil {
		return DefaultMaxConcurrent
	}
	// Hardware-based cap using total memory reported by the provider.
	memGB := p.BackendCapacity.TotalMemoryGB
	if memGB <= 0 {
		memGB = float64(p.Hardware.MemoryGB)
	}
	var cap int
	switch {
	case memGB <= 24:
		cap = 4
	case memGB <= 48:
		cap = 8
	case memGB <= 96:
		cap = 16
	case memGB <= 128:
		cap = 24
	default:
		cap = 32
	}
	return cap
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

	// store provides persistence for provider fleet state. When non-nil,
	// provider records and reputation are persisted across coordinator restarts.
	store store.Store

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

// SetStore configures the persistence store for the registry.
// When set, provider state and reputation are persisted to the store.
func (r *Registry) SetStore(st store.Store) {
	r.store = st
}

// LoadStoredProviders loads provider records and reputation from the store
// on startup. This pre-populates a lookup table so that reconnecting providers
// can have their trust level and reputation restored. Providers are NOT added
// to the active registry (they need to reconnect via WebSocket first).
func (r *Registry) LoadStoredProviders() map[string]*store.ProviderRecord {
	if r.store == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	records, err := r.store.ListProviderRecords(ctx)
	if err != nil {
		r.logger.Warn("failed to load stored providers", "error", err)
		return nil
	}

	lookup := make(map[string]*store.ProviderRecord, len(records))
	for i := range records {
		rec := records[i]
		// Index by serial number for matching reconnecting providers
		if rec.SerialNumber != "" {
			lookup[rec.SerialNumber] = &rec
		}
		// Also index by SE public key
		if rec.SEPublicKey != "" {
			lookup["sekey:"+rec.SEPublicKey] = &rec
		}
	}

	r.logger.Info("loaded stored provider records", "count", len(records))
	return lookup
}

// RestoreProviderState restores trust level and reputation from a stored record
// onto a live provider. Called after a provider reconnects and is matched to
// its stored state by serial number or SE key.
func (r *Registry) RestoreProviderState(p *Provider, rec *store.ProviderRecord) {
	if rec == nil {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	// Restore trust level (will be re-verified via fresh attestation)
	p.TrustLevel = TrustLevel(rec.TrustLevel)
	p.Attested = rec.Attested
	p.MDAVerified = rec.MDAVerified
	p.ACMEVerified = rec.ACMEVerified

	// Restore challenge state
	if rec.LastChallengeVerified != nil {
		p.LastChallengeVerified = *rec.LastChallengeVerified
	}
	p.FailedChallenges = rec.FailedChallenges

	// Restore account linkage
	if rec.AccountID != "" && p.AccountID == "" {
		p.AccountID = rec.AccountID
	}

	// Restore lifetime counters and the last raw session counters so future
	// heartbeats can merge cleanly after coordinator or provider restarts.
	p.Stats = protocol.HeartbeatStats{
		RequestsServed:  rec.LifetimeRequestsServed,
		TokensGenerated: rec.LifetimeTokensGenerated,
	}
	p.lastSessionStats = protocol.HeartbeatStats{
		RequestsServed:  rec.LastSessionRequestsServed,
		TokensGenerated: rec.LastSessionTokensGenerated,
	}

	// Restore reputation from store
	if r.store != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		repRec, err := r.store.GetReputation(ctx, rec.ID)
		if err == nil {
			p.Reputation.TotalJobs = repRec.TotalJobs
			p.Reputation.SuccessfulJobs = repRec.SuccessfulJobs
			p.Reputation.FailedJobs = repRec.FailedJobs
			p.Reputation.TotalUptime = time.Duration(repRec.TotalUptimeSeconds) * time.Second
			p.Reputation.AvgResponseTime = time.Duration(repRec.AvgResponseTimeMs) * time.Millisecond
			p.Reputation.ChallengesPassed = repRec.ChallengesPassed
			p.Reputation.ChallengesFailed = repRec.ChallengesFailed
		}
	}

	r.logger.Info("restored provider state from store",
		"provider_id", p.ID,
		"stored_id", rec.ID,
		"trust_level", rec.TrustLevel,
		"attested", rec.Attested,
		"serial", rec.SerialNumber,
	)
}

// PersistProvider is the public entry point for persisting a provider's state.
// Called by the API layer after attestation and trust changes.
func (r *Registry) PersistProvider(p *Provider) {
	r.persistProvider(p)
}

// persistProvider saves a provider's current state to the store.
// Called asynchronously to avoid blocking the hot path.
func (r *Registry) persistProvider(p *Provider) {
	if r.store == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		p.mu.Lock()
		hardwareJSON, _ := json.Marshal(p.Hardware)
		modelsJSON, _ := json.Marshal(p.Models)
		var attestJSON json.RawMessage
		if p.AttestationResult != nil {
			attestJSON, _ = json.Marshal(p.AttestationResult)
		}
		seKey := ""
		serial := ""
		if p.AttestationResult != nil {
			seKey = p.AttestationResult.PublicKey
			serial = p.AttestationResult.SerialNumber
		}
		var mdaCertJSON json.RawMessage
		if len(p.MDACertChain) > 0 {
			mdaCertJSON, _ = json.Marshal(p.MDACertChain)
		}
		var lastChallenge *time.Time
		if !p.LastChallengeVerified.IsZero() {
			t := p.LastChallengeVerified
			lastChallenge = &t
		}

		rec := store.ProviderRecord{
			ID:                         p.ID,
			Hardware:                   hardwareJSON,
			Models:                     modelsJSON,
			Backend:                    p.Backend,
			TrustLevel:                 string(p.TrustLevel),
			Attested:                   p.Attested,
			AttestationResult:          attestJSON,
			SEPublicKey:                seKey,
			SerialNumber:               serial,
			MDAVerified:                p.MDAVerified,
			MDACertChain:               mdaCertJSON,
			ACMEVerified:               p.ACMEVerified,
			Version:                    p.Version,
			RuntimeVerified:            p.RuntimeVerified,
			PythonHash:                 p.PythonHash,
			RuntimeHash:                p.RuntimeHash,
			LastChallengeVerified:      lastChallenge,
			FailedChallenges:           p.FailedChallenges,
			AccountID:                  p.AccountID,
			LifetimeRequestsServed:     p.Stats.RequestsServed,
			LifetimeTokensGenerated:    p.Stats.TokensGenerated,
			LastSessionRequestsServed:  p.lastSessionStats.RequestsServed,
			LastSessionTokensGenerated: p.lastSessionStats.TokensGenerated,
			RegisteredAt:               time.Now(),
			LastSeen:                   time.Now(),
		}
		p.mu.Unlock()

		if err := r.store.UpsertProvider(ctx, rec); err != nil {
			r.logger.Warn("failed to persist provider", "provider_id", p.ID, "error", err)
		}
	}()
}

// persistReputation saves a provider's current reputation to the store.
// Called asynchronously to avoid blocking the hot path.
func (r *Registry) persistReputation(p *Provider) {
	if r.store == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		p.mu.Lock()
		rep := store.ReputationRecord{
			TotalJobs:          p.Reputation.TotalJobs,
			SuccessfulJobs:     p.Reputation.SuccessfulJobs,
			FailedJobs:         p.Reputation.FailedJobs,
			TotalUptimeSeconds: int64(p.Reputation.TotalUptime / time.Second),
			AvgResponseTimeMs:  int64(p.Reputation.AvgResponseTime / time.Millisecond),
			ChallengesPassed:   p.Reputation.ChallengesPassed,
			ChallengesFailed:   p.Reputation.ChallengesFailed,
		}
		p.mu.Unlock()

		if err := r.store.UpsertReputation(ctx, p.ID, rep); err != nil {
			r.logger.Warn("failed to persist reputation", "provider_id", p.ID, "error", err)
		}
	}()
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

	// Persist provider record to store (async).
	r.persistProvider(p)

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
	p.Stats.RequestsServed += cumulativeDelta(p.lastSessionStats.RequestsServed, msg.Stats.RequestsServed)
	p.Stats.TokensGenerated += cumulativeDelta(p.lastSessionStats.TokensGenerated, msg.Stats.TokensGenerated)
	p.lastSessionStats = msg.Stats
	p.SystemMetrics = msg.SystemMetrics
	// Update backend capacity from heartbeat (nil-safe for old providers).
	if msg.BackendCapacity != nil {
		p.BackendCapacity = msg.BackendCapacity
	}
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

	r.PersistProvider(p)

	// Heartbeats can make a recovered slot routable again (for example after a
	// crash auto-restart). Drain matching queues using the canonical scheduler
	// rather than the legacy direct queue assignment path.
	r.drainQueuedRequestsForModels(providerModelIDs(p))
}

func cumulativeDelta(previous, current int64) int64 {
	if current <= 0 {
		return 0
	}
	if current >= previous {
		return current - previous
	}
	// The provider process restarted and reset its in-memory counters.
	return current
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

	// Persist trust state.
	r.persistProvider(p)
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
	p.Reputation.RecordChallengePass()
	p.mu.Unlock()

	// Persist challenge state and reputation.
	r.persistProvider(p)
	r.persistReputation(p)

	// A newly verified provider may unlock queued requests for any model it serves.
	r.drainQueuedRequestsForModels(providerModelIDs(p))
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
	p.Reputation.RecordChallengeFail()
	count := p.FailedChallenges
	p.mu.Unlock()

	// Persist challenge state and reputation.
	r.persistProvider(p)
	r.persistReputation(p)

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

// DefaultMaxConcurrent is the fallback concurrency limit for providers
// that don't report backend capacity. Providers that report BackendCapacity
// in heartbeats get a dynamic limit based on their total memory.
const DefaultMaxConcurrent = 4

// MaxConcurrentRequests is kept as an alias for backward compatibility
// with tests and external code that reference the old constant name.
const MaxConcurrentRequests = DefaultMaxConcurrent

// ScoreProvider calculates a routing score for a provider.
// Higher scores indicate better routing candidates.
// Score = (1 - load) * decode_tps * trust_multiplier * reputation * warm_bonus * health_factor
//
// Uses dynamic max based on hardware when backend capacity is reported.
// scoreSnapshot holds the mutable provider fields needed by ScoreProvider,
// captured under the provider lock to avoid repeated locking.
type scoreSnapshot struct {
	runtimeVerified bool
	maxConcurrency  int
	decodeTPS       float64
	trustLevel      TrustLevel
	warmModels      []string
	currentModel    string
	sysMetrics      protocol.SystemMetrics
	repScore        float64
	backendCap      *protocol.BackendCapacity
	memBandwidthGBs float64
	memoryGB        int
}

func snapshotForScore(p *Provider) scoreSnapshot {
	pending := p.PendingCount()
	_ = pending
	p.mu.Lock()
	defer p.mu.Unlock()
	return scoreSnapshot{
		runtimeVerified: p.RuntimeVerified,
		maxConcurrency:  p.maxConcurrency(),
		decodeTPS:       p.DecodeTPS,
		trustLevel:      p.TrustLevel,
		warmModels:      append([]string{}, p.WarmModels...),
		currentModel:    p.CurrentModel,
		sysMetrics:      p.SystemMetrics,
		repScore:        p.Reputation.Score(),
		backendCap:      p.BackendCapacity,
		memBandwidthGBs: p.Hardware.MemoryBandwidthGBs,
		memoryGB:        p.Hardware.MemoryGB,
	}
}

// estimateDecodeTPS returns the effective decode TPS, falling back to
// a sqrt-scaled hardware bandwidth estimate when the provider has not
// reported a value.
func estimateDecodeTPS(reported float64, memBandwidthGBs float64) float64 {
	if reported > 0 {
		return reported
	}
	bw := memBandwidthGBs
	if bw > 0 {
		return math.Sqrt(bw) // sqrt scaling: 546→23.4, 400→20, 300→17.3, 150→12.2
	}
	return 1.0
}

// warmModelBonus returns a multiplier for providers that already have the
// requested model warm in cache. Only applies when the provider is idle.
func warmModelBonus(model string, warmModels []string, currentModel string, idle bool) float64 {
	if !idle {
		return 1.0
	}
	for _, wm := range warmModels {
		if wm == model {
			return 1.5
		}
	}
	if currentModel == model {
		return 1.5
	}
	return 1.0
}

// slotStateWarmOverride adjusts the warm bonus based on backend slot state.
// Providers whose backend is DOWN get a heavy penalty.
func slotStateWarmOverride(backendCap *protocol.BackendCapacity, model string, warmBonus float64) float64 {
	if backendCap == nil {
		return warmBonus
	}
	for _, slot := range backendCap.Slots {
		if slot.Model == model {
			switch slot.State {
			case "idle_shutdown":
				return 0.1
			case "crashed":
				return 0.05
			}
			return warmBonus
		}
	}
	return warmBonus
}

// computeHealthFactor returns a combined health multiplier from system
// metrics and GPU memory pressure.
func computeHealthFactor(m protocol.SystemMetrics, backendCap *protocol.BackendCapacity, hwMemoryGB int) float64 {
	memFactor := 1.0 - m.MemoryPressure
	if memFactor < 0.1 {
		memFactor = 0.1
	}
	cpuFactor := 1.0 - (m.CPUUsage * 0.5)

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
	healthFactor *= gpuMemoryFactor(backendCap, hwMemoryGB)
	return healthFactor
}

// gpuMemoryFactor penalizes providers with high GPU utilization.
func gpuMemoryFactor(backendCap *protocol.BackendCapacity, hwMemoryGB int) float64 {
	if backendCap == nil || backendCap.GPUMemoryActiveGB <= 0 {
		return 1.0
	}
	totalMem := backendCap.TotalMemoryGB
	if totalMem <= 0 {
		totalMem = float64(hwMemoryGB)
	}
	if totalMem <= 0 {
		return 1.0
	}
	gpuUtil := backendCap.GPUMemoryActiveGB / totalMem
	gpuFactor := 1.0 - (gpuUtil * 0.5)
	if gpuFactor < 0.1 {
		gpuFactor = 0.1
	}
	return gpuFactor
}

func ScoreProvider(p *Provider, model string) float64 {
	snap := snapshotForScore(p)
	if !snap.runtimeVerified {
		return 0
	}

	pending := float64(p.PendingCount())
	load := pending / float64(snap.maxConcurrency)
	if load > 1.0 {
		load = 1.0
	}

	decodeTPS := estimateDecodeTPS(snap.decodeTPS, snap.memBandwidthGBs)
	trustMul := TrustMultiplier(snap.trustLevel)
	wb := warmModelBonus(model, snap.warmModels, snap.currentModel, pending == 0)
	wb = slotStateWarmOverride(snap.backendCap, model, wb)
	healthFactor := computeHealthFactor(snap.sysMetrics, snap.backendCap, snap.memoryGB)

	return (1.0 - load) * decodeTPS * trustMul * snap.repScore * wb * healthFactor
}

// FindProvider selects an available provider for the given model using
// intelligent scoring based on benchmark data, trust level, reputation,
// warm model cache, and backend capacity. Picks the highest-scoring
// provider that has concurrency headroom (dynamic limit based on hardware).
// Optional excludeIDs are provider IDs to skip (e.g. providers that
// already failed for this request during retry).
func (r *Registry) FindProvider(model string, excludeIDs ...string) *Provider {
	return r.FindProviderWithTrust(model, "", excludeIDs...)
}

// FindProviderWithTrust selects a provider with an optional per-request
// minimum trust level. If minTrust is empty, the registry's default
// MinTrustLevel is used. Consumers can request a specific trust level
// (e.g. hardware) to filter providers. Optional excludeIDs are provider
// IDs to skip during selection.
// providerEligibility holds the snapshot fields used to determine whether
// a provider is eligible for routing in FindProviderWithTrust.
type providerEligibility struct {
	status          ProviderStatus
	trust           TrustLevel
	lastChallenge   time.Time
	runtimeVerified bool
}

// isEligible checks whether a provider is eligible for routing given the
// effective minimum trust, current time, and challenge max age.
func (e providerEligibility) isEligible(effectiveMin TrustLevel, now time.Time, challengeMaxAge time.Duration) bool {
	if e.status == StatusOffline || e.status == StatusUntrusted {
		return false
	}
	if trustRank(e.trust) < trustRank(effectiveMin) {
		return false
	}
	if !e.runtimeVerified {
		return false
	}
	if e.lastChallenge.IsZero() || now.Sub(e.lastChallenge) > challengeMaxAge {
		return false
	}
	return true
}

// selectHighestScoredProvider picks the best provider from a list of
// candidates using ScoreProvider, with random tie-breaking.
func selectHighestScoredProvider(candidates []*Provider, model string) *Provider {
	if len(candidates) == 0 {
		return nil
	}

	bestIdx := 0
	bestScore := ScoreProvider(candidates[0], model)
	for i := 1; i < len(candidates); i++ {
		s := ScoreProvider(candidates[i], model)
		if s > bestScore {
			bestScore = s
			bestIdx = i
		}
	}

	var ties []*Provider
	for _, c := range candidates {
		if ScoreProvider(c, model) >= bestScore-0.001 {
			ties = append(ties, c)
		}
	}
	if len(ties) > 1 {
		return ties[rand.Intn(len(ties))]
	}
	return candidates[bestIdx]
}

func (r *Registry) FindProviderWithTrust(model string, minTrust TrustLevel, excludeIDs ...string) *Provider {
	r.mu.Lock()
	defer r.mu.Unlock()

	excludeSet := make(map[string]struct{}, len(excludeIDs))
	for _, id := range excludeIDs {
		excludeSet[id] = struct{}{}
	}

	effectiveMin := r.MinTrustLevel
	if minTrust != "" && trustRank(minTrust) > trustRank(effectiveMin) {
		effectiveMin = minTrust
	}

	challengeMaxAge := 6 * time.Minute
	now := time.Now()

	var candidates []*Provider
	for _, p := range r.providers {
		if _, excluded := excludeSet[p.ID]; excluded {
			continue
		}

		p.mu.Lock()
		elig := providerEligibility{
			status:          p.Status,
			trust:           p.TrustLevel,
			lastChallenge:   p.LastChallengeVerified,
			runtimeVerified: p.RuntimeVerified,
		}
		p.mu.Unlock()

		if !elig.isEligible(effectiveMin, now, challengeMaxAge) {
			continue
		}
		if p.PendingCount() >= p.MaxConcurrency() {
			continue
		}
		if providerServesModelLocked(p, model) {
			candidates = append(candidates, p)
		}
	}

	selected := selectHighestScoredProvider(candidates, model)
	if selected == nil {
		return nil
	}

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
	if p.pendingCount() == 0 && p.Status != StatusUntrusted && p.Status != StatusOffline {
		p.Status = StatusOnline
	}
	p.mu.Unlock()

	// Use all newly available capacity, not just a single queued request.
	r.drainQueuedRequestsForModels(providerModelIDs(p))
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

// modelAgg accumulates per-model statistics across providers for ListModels.
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

// aggregateProviderModels merges a single provider's models into the
// aggregation map, updating counts, trust, and attestation flags.
func aggregateProviderModels(p *Provider, trust TrustLevel, attested bool, attestResult *attestation.VerificationResult, agg map[string]*modelAgg) {
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

// ListModels returns deduplicated models from all online providers.
func (r *Registry) ListModels() []AggregateModel {
	r.mu.RLock()
	defer r.mu.RUnlock()

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
		aggregateProviderModels(p, trust, attested, attestResult, agg)
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

	// Persist reputation.
	r.persistReputation(p)
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

	// Persist reputation.
	r.persistReputation(p)
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
