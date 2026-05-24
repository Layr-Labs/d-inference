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
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
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

const (
	BackendInprocessMLX = "inprocess-mlx"
	BackendMLXSwift     = "mlx-swift"
)

func BackendUsesSwiftRuntime(backend string) bool {
	return backend == BackendMLXSwift
}

// PendingRequest is a channel-based handle for an in-flight inference request.
type PendingRequest struct {
	RequestID   string
	ProviderID  string
	Model       string
	ConsumerKey string
	// IsResponsesAPI tracks requests received through /v1/responses so the
	// coordinator can translate provider chat-completions output back into
	// Responses API objects for SDK clients.
	IsResponsesAPI bool
	// AllowedProviderSerials optionally restricts routing to providers with
	// one of these attested hardware serials. Empty means the request may
	// route to any eligible provider.
	AllowedProviderSerials []string
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

	// ReservedMicroUSD is the balance atomically debited at pre-flight.
	// The post-inference charge adjusts for the difference between the
	// actual cost and this reservation, preventing billing race conditions.
	ReservedMicroUSD     int64
	reservationMu        sync.Mutex
	reservationFinalized bool

	// Timing fields for latency decomposition.
	Timing *RequestTiming
}

// MarkReservationFinalized returns true only for the first settlement or refund
// of a pre-flight balance reservation. It prevents a terminal provider error
// racing with a late completion from crediting or refunding the same reservation
// twice.
func (pr *PendingRequest) MarkReservationFinalized() bool {
	ok, _ := pr.FinalizeReservation(nil)
	return ok
}

// FinalizeReservation runs settle while holding the reservation finalization
// lock and marks the reservation finalized only if settle succeeds. It returns
// false when another terminal path already finalized the reservation.
func (pr *PendingRequest) FinalizeReservation(settle func() error) (bool, error) {
	pr.reservationMu.Lock()
	defer pr.reservationMu.Unlock()
	if pr.reservationFinalized {
		return false, nil
	}
	if settle != nil {
		if err := settle(); err != nil {
			return false, err
		}
	}
	pr.reservationFinalized = true
	return true, nil
}

type RequestTiming struct {
	ReceivedAt   time.Time // handler entry
	ParsedAt     time.Time // after parse + validate
	ReservedAt   time.Time // after balance reservation
	RoutedAt     time.Time // after provider selection (including queue wait)
	EncryptedAt  time.Time // after E2E encryption
	QueuedAt     time.Time // set when request enters the queue
	DispatchedAt time.Time // set when request is sent to provider via WebSocket
	FirstChunkAt time.Time // set when first inference chunk arrives from provider
}

// Provider represents a connected provider agent.
type Provider struct {
	ID                string
	Hardware          protocol.Hardware
	Models            []protocol.ModelInfo
	Backend           string
	PublicKey         string // base64-encoded X25519 public key for E2E encryption
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
	Version                 string `json:"version,omitempty"`                   // provider binary version (e.g. "0.2.31")
	RuntimeVerified         bool   `json:"runtime_verified"`                    // true if runtime hashes match the known-good manifest
	RuntimeManifestChecked  bool   `json:"runtime_manifest_checked"`            // true only when a manifest was present and hashes were verified (fail-closed for text)
	EncryptedResponseChunks bool   `json:"encrypted_response_chunks,omitempty"` // true when text response chunks are encrypted to the coordinator
	PythonHash              string `json:"python_hash,omitempty"`
	RuntimeHash             string `json:"runtime_hash,omitempty"`
	TemplateHashes          map[string]string

	// Phase 7: Privacy invariant attestation.
	// Self-reported by the provider at registration. SIPEnabled is overridden
	// by the coordinator after each attestation challenge response with a
	// coordinator-verified value. HypervisorActive is informational.
	PrivacyCapabilities *protocol.PrivacyCapabilities `json:"privacy_capabilities,omitempty"`

	// Coordinator-verified SIP status from the most recent attestation challenge.
	// Unlike PrivacyCapabilities.SIPEnabled (provider self-report at registration),
	// this is set by the coordinator after independently checking the challenge response.
	ChallengeVerifiedSIP bool `json:"challenge_verified_sip"`

	// Challenge-response verification state
	LastChallengeVerified time.Time // last successful challenge verification
	FailedChallenges      int       // consecutive failed challenges

	mu          sync.Mutex
	pendingReqs map[string]*PendingRequest
}

func providerSupportsPrivateTextLocked(p *Provider) bool {
	if p.PublicKey == "" || !privateTextBackendSupported(p.Backend) || !p.EncryptedResponseChunks {
		return false
	}
	if !p.RuntimeManifestChecked {
		return false
	}
	// Require coordinator-verified SIP (from attestation challenge) rather
	// than trusting the provider's self-reported SIPEnabled field.
	if !p.ChallengeVerifiedSIP {
		return false
	}
	swiftRuntime := BackendUsesSwiftRuntime(p.Backend)
	caps := p.PrivacyCapabilities
	if caps == nil {
		return false
	}
	base := caps.TextBackendInprocess &&
		caps.TextProxyDisabled &&
		caps.AntiDebugEnabled &&
		caps.CoreDumpsDisabled &&
		caps.EnvScrubbed
	if swiftRuntime {
		return base
	}
	return base &&
		caps.PythonRuntimeLocked &&
		caps.DangerousModulesBlocked
}

func privateTextBackendSupported(backend string) bool {
	return backend == BackendInprocessMLX || backend == BackendMLXSwift
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

// GetLastChallengeVerified returns the last challenge verification time (thread-safe).
func (p *Provider) GetLastChallengeVerified() time.Time {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.LastChallengeVerified
}

// GetChallengeVerifiedSIP returns whether SIP was verified in the last challenge (thread-safe).
func (p *Provider) GetChallengeVerifiedSIP() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.ChallengeVerifiedSIP
}

func (p *Provider) SetChallengeVerifiedSIP(v bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.ChallengeVerifiedSIP = v
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

// GetAttestationResult returns the current attestation result (thread-safe).
func (p *Provider) GetAttestationResult() *attestation.VerificationResult {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.AttestationResult
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

// MaxConcurrencyForModel returns the concurrency limit for a specific model.
// A positive provider-reported slot cap wins; zero/missing preserves the
// legacy provider-level fallback.
func (p *Provider) MaxConcurrencyForModel(model string) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.maxConcurrencyForModelLocked(model)
}

// maxConcurrency is the lock-free version (caller must hold p.mu).
//
// Tier values were lowered in Phase 2 of the routing-algorithm rework
// (was 4/8/16/24/32). The old caps were derived from "how many
// requests can theoretically fit in GPU memory"; the new caps reflect
// "how many concurrent decodes a single MLX backend can run before
// per-request TPS collapses". Empirically this is much smaller than
// the memory-derived ceiling. Pushing past it makes each request slow
// without increasing fleet throughput.
func (p *Provider) maxConcurrency() int {
	if p.BackendCapacity == nil {
		return DefaultMaxConcurrent
	}

	// Token-budget providers use budget-based admission; the concurrency
	// cap is just a safety valve.
	for _, slot := range p.BackendCapacity.Slots {
		if slot.ActiveTokenBudgetMax > 0 {
			return 24
		}
	}

	// Hardware-based cap using total memory reported by the provider.
	memGB := p.BackendCapacity.TotalMemoryGB
	if memGB <= 0 {
		memGB = float64(p.Hardware.MemoryGB)
	}
	var cap int
	switch {
	case memGB <= 24:
		cap = 2
	case memGB <= 48:
		cap = 4
	case memGB <= 96:
		cap = 6
	case memGB <= 128:
		cap = 8
	default:
		cap = 12
	}
	return cap
}

// maxConcurrencyForModelLocked is the lock-free model-aware concurrency cap.
// Caller must hold p.mu.
func (p *Provider) maxConcurrencyForModelLocked(model string) int {
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == model && slot.MaxConcurrency > 0 {
				return slot.MaxConcurrency
			}
		}
	}
	return p.maxConcurrency()
}

func (p *Provider) pendingCountForModelLocked(model string) int {
	count := 0
	for _, pr := range p.pendingReqs {
		if pr.Model == model {
			count++
		}
	}
	return count
}

func (p *Provider) hasReportedMaxConcurrencyForModelLocked(model string) bool {
	if p.BackendCapacity == nil {
		return false
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == model && slot.MaxConcurrency > 0 {
			return true
		}
	}
	return false
}

func (p *Provider) pendingLoadForModelLocked(model string) int {
	if !p.hasReportedMaxConcurrencyForModelLocked(model) {
		return p.pendingCount()
	}
	load := p.pendingCountForModelLocked(model)
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			backendLoad := slot.NumRunning + slot.NumWaiting
			if backendLoad > load {
				load = backendLoad
			}
			break
		}
	}
	return load
}

func (p *Provider) hasConcurrencyHeadroomForModelLocked(model string) bool {
	return p.pendingLoadForModelLocked(model) < p.maxConcurrencyForModelLocked(model) &&
		p.pendingCount() < p.maxConcurrency()
}

// Registry holds all connected providers and provides routing.
type Registry struct {
	mu        sync.RWMutex
	providers map[string]*Provider

	queue *RequestQueue

	MinTrustLevel TrustLevel

	modelCatalog map[string]CatalogEntry

	store store.Store

	tpsRegistry *TPSRegistry

	logger *slog.Logger

	onlineCount      atomic.Int64
	modelProviders   map[string]*atomic.Int64
	modelProvidersMu sync.Mutex
}

// New creates a new Registry.
func New(logger *slog.Logger) *Registry {
	return &Registry{
		providers:      make(map[string]*Provider),
		queue:          NewRequestQueue(10, 120*time.Second),
		MinTrustLevel:  TrustHardware,
		tpsRegistry:    NewTPSRegistry(),
		modelProviders: make(map[string]*atomic.Int64),
		logger:         logger,
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
	saferun.Go(r.logger, "registry.persistProvider", func() {
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
	})
}

// persistReputation saves a provider's current reputation to the store.
// Called asynchronously to avoid blocking the hot path.
func (r *Registry) persistReputation(p *Provider) {
	if r.store == nil {
		return
	}
	saferun.Go(r.logger, "registry.persistReputation", func() {
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
	})
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
	WeightHash string  // expected SHA-256 weight fingerprint (empty = not enforced)
	SizeGB     float64 // disk/GPU footprint of the model weights (zero = unknown, gate disabled)
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

// ModelType returns the model type string for the given model ID, or
// "unknown" if no provider is currently serving it.
func (r *Registry) ModelType(model string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		for _, m := range p.Models {
			if m.ID == model && m.ModelType != "" {
				p.mu.Unlock()
				return m.ModelType
			}
		}
		p.mu.Unlock()
	}
	return "unknown"
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

// catalogSizeGBLocked returns the model's reported weight footprint in GB,
// or 0 when unknown. Caller must hold r.mu (read or write). Zero means the
// memory-admission gate should not enforce for this model — typically a
// catalog entry that pre-dates the SizeGB field, or a model the operator
// hasn't sized yet.
func (r *Registry) catalogSizeGBLocked(model string) float64 {
	if e, ok := r.modelCatalog[model]; ok {
		return e.SizeGB
	}
	return 0
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

// Sanity caps on provider-reported stats. A malicious (or broken) provider
// could otherwise report absurd values to monopolize routing. These caps are
// ~3-4x current hardware ceilings (M2 Ultra is ~800 GB/s, MLX decode is ~120
// tok/s, max Mac Studio RAM is 512 GB) so legitimate future hardware isn't
// clamped unnecessarily.
const (
	maxDecodeTPS                    = 500.0
	maxPrefillTPS                   = 5000.0
	maxMemoryBandwidthGBs           = 2000.0
	maxMemoryGB                     = 1024
	maxMemoryGBFloat                = 1024.0
	maxReportedMaxConcurrency       = 24
	maxTokensPotential              = 1_000_000
	maxTokenBudgetCap         int64 = 10_000_000_000 // 10 billion — generous safety valve for total token budget capacity
)

// clampNonNeg returns v clamped into [0, max]; NaN/negative become 0.
// The bool is true if the value was out of range.
func clampNonNeg(v, max float64) (float64, bool) {
	if math.IsNaN(v) || v < 0 {
		return 0, true
	}
	if v > max {
		return max, true
	}
	return v, false
}

// clampBackendCapacity applies sanity caps to provider-reported backend
// capacity fields that feed the routing scorer. A provider reporting
// TotalMemoryGB=1e9 would make gpuUtil ~= 0 and dodge health penalties, so
// we cap it at maxMemoryGBFloat. Same for MaxTokensPotential which directly
// controls backlog cost. NaN/negative become 0.
func clampBackendCapacity(logger *slog.Logger, providerID string, bc *protocol.BackendCapacity) {
	if bc == nil {
		return
	}
	if v, changed := clampNonNeg(bc.TotalMemoryGB, maxMemoryGBFloat); changed {
		logger.Warn("provider total_memory_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.TotalMemoryGB, "clamped", v)
		bc.TotalMemoryGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryActiveGB, maxMemoryGBFloat); changed {
		logger.Warn("provider gpu_memory_active_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.GPUMemoryActiveGB, "clamped", v)
		bc.GPUMemoryActiveGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryPeakGB, maxMemoryGBFloat); changed {
		bc.GPUMemoryPeakGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryCacheGB, maxMemoryGBFloat); changed {
		bc.GPUMemoryCacheGB = v
	}
	for i := range bc.Slots {
		s := &bc.Slots[i]
		if s.MaxTokensPotential < 0 || s.MaxTokensPotential > maxTokensPotential {
			logger.Warn("provider slot max_tokens_potential out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxTokensPotential)
			if s.MaxTokensPotential < 0 {
				s.MaxTokensPotential = 0
			} else {
				s.MaxTokensPotential = maxTokensPotential
			}
		}
		if s.NumRunning < 0 {
			s.NumRunning = 0
		}
		if s.NumWaiting < 0 {
			s.NumWaiting = 0
		}
		if s.MaxConcurrency < 0 || s.MaxConcurrency > maxReportedMaxConcurrency {
			logger.Warn("provider slot max_concurrency out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxConcurrency)
			if s.MaxConcurrency < 0 {
				s.MaxConcurrency = 0
			} else {
				s.MaxConcurrency = maxReportedMaxConcurrency
			}
		}
		if v, changed := clampNonNeg(s.ObservedDecodeTPS, maxDecodeTPS); changed {
			logger.Warn("provider slot observed_decode_tps out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.ObservedDecodeTPS, "clamped", v)
			s.ObservedDecodeTPS = v
		}
		if s.ActiveTokenBudgetUsed < 0 || s.ActiveTokenBudgetUsed > maxTokenBudgetCap {
			if s.ActiveTokenBudgetUsed < 0 {
				s.ActiveTokenBudgetUsed = 0
			} else {
				s.ActiveTokenBudgetUsed = maxTokenBudgetCap
			}
		}
		if s.ActiveTokenBudgetMax < 0 || s.ActiveTokenBudgetMax > maxTokenBudgetCap {
			if s.ActiveTokenBudgetMax < 0 {
				s.ActiveTokenBudgetMax = 0
			} else {
				s.ActiveTokenBudgetMax = maxTokenBudgetCap
			}
		}
		if s.QueuedTokenBudget < 0 || s.QueuedTokenBudget > maxTokenBudgetCap {
			if s.QueuedTokenBudget < 0 {
				s.QueuedTokenBudget = 0
			} else {
				s.QueuedTokenBudget = maxTokenBudgetCap
			}
		}
	}
}

// Register adds a new provider to the registry, returning its assigned ID.
// If a model catalog is configured, only models in the catalog are kept.
func (r *Registry) Register(id string, conn *websocket.Conn, msg *protocol.RegisterMessage) *Provider {
	// Clamp provider-reported performance stats used in routing score.
	// Refuse to trust unbounded values — a malicious provider reporting
	// DecodeTPS=1e9 would otherwise starve all other providers.
	if v, changed := clampNonNeg(msg.DecodeTPS, maxDecodeTPS); changed {
		r.logger.Warn("provider decode_tps out of range, clamping",
			"provider_id", id, "reported", msg.DecodeTPS, "clamped", v)
		msg.DecodeTPS = v
	}
	if v, changed := clampNonNeg(msg.PrefillTPS, maxPrefillTPS); changed {
		r.logger.Warn("provider prefill_tps out of range, clamping",
			"provider_id", id, "reported", msg.PrefillTPS, "clamped", v)
		msg.PrefillTPS = v
	}
	if v, changed := clampNonNeg(msg.Hardware.MemoryBandwidthGBs, maxMemoryBandwidthGBs); changed {
		r.logger.Warn("provider memory_bandwidth_gbs out of range, clamping",
			"provider_id", id, "reported", msg.Hardware.MemoryBandwidthGBs, "clamped", v)
		msg.Hardware.MemoryBandwidthGBs = v
	}
	if msg.Hardware.MemoryGB < 0 || msg.Hardware.MemoryGB > maxMemoryGB {
		r.logger.Warn("provider memory_gb out of range, clamping",
			"provider_id", id, "reported", msg.Hardware.MemoryGB)
		if msg.Hardware.MemoryGB < 0 {
			msg.Hardware.MemoryGB = 0
		} else {
			msg.Hardware.MemoryGB = maxMemoryGB
		}
	}

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
		ID:                      id,
		Hardware:                msg.Hardware,
		Models:                  models,
		Backend:                 msg.Backend,
		PublicKey:               pubKey,
		EncryptedResponseChunks: msg.EncryptedResponseChunks,
		PrefillTPS:              msg.PrefillTPS,
		DecodeTPS:               msg.DecodeTPS,
		TrustLevel:              TrustNone,
		RuntimeVerified:         true,  // default to verified; API layer sets false when manifest check fails
		RuntimeManifestChecked:  true,  // default to true; API layer sets false when no manifest is configured
		ChallengeVerifiedSIP:    false, // starts false; set true by attestation challenge handler after SIP check
		PrivacyCapabilities:     msg.PrivacyCapabilities,
		TemplateHashes:          CloneStringMap(msg.TemplateHashes),
		Status:                  StatusOnline,
		Conn:                    conn,
		LastHeartbeat:           time.Now(),
		Reputation:              NewReputation(),
		pendingReqs:             make(map[string]*PendingRequest),
	}

	r.mu.Lock()
	r.providers[id] = p
	r.onlineCount.Add(1)
	for _, m := range models {
		r.modelProviderInc(m.ID)
	}
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

func CloneStringMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
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

	// Clamp heartbeat-reported capacity and metrics so a malicious provider
	// can't skew routing by reporting absurd values (e.g. TotalMemoryGB=1e9
	// would drive gpuUtil to 0 and sidestep health penalties).
	clampBackendCapacity(r.logger, id, msg.BackendCapacity)
	if v, changed := clampNonNeg(msg.SystemMetrics.MemoryPressure, 1.0); changed {
		msg.SystemMetrics.MemoryPressure = v
	}
	if v, changed := clampNonNeg(msg.SystemMetrics.CPUUsage, 1.0); changed {
		msg.SystemMetrics.CPUUsage = v
	}

	p.mu.Lock()
	p.LastHeartbeat = time.Now()
	p.Stats.RequestsServed += cumulativeDelta(p.lastSessionStats.RequestsServed, msg.Stats.RequestsServed)
	p.Stats.TokensGenerated += cumulativeDelta(p.lastSessionStats.TokensGenerated, msg.Stats.TokensGenerated)
	p.lastSessionStats = msg.Stats
	p.SystemMetrics = msg.SystemMetrics
	// Update backend capacity from heartbeat. A nil report clears prior live
	// capacity so stale slot state cannot keep influencing routing.
	p.BackendCapacity = msg.BackendCapacity
	if p.BackendCapacity != nil {
		chipFamily := p.Hardware.ChipFamily
		for _, slot := range p.BackendCapacity.Slots {
			if slot.ObservedDecodeTPS > 0 {
				r.tpsRegistry.Record(slot.Model, chipFamily, slot.ObservedDecodeTPS)
			}
		}
	}
	// Update warm models from heartbeat
	if len(msg.WarmModels) > 0 {
		p.WarmModels = msg.WarmModels
	}
	if msg.ActiveModel != nil {
		p.CurrentModel = *msg.ActiveModel
	}
	// Only update status from heartbeat if provider is not actively serving
	// (serving status is managed by request lifecycle). Crucially, an
	// untrusted provider must NOT transition back to StatusOnline here —
	// that would cause an onlineCount double-decrement when Disconnect
	// later sees StatusOnline and decrements a second time.
	if p.Status == StatusUntrusted {
		// no status transitions allowed
	} else if p.Status != StatusServing || msg.Status == "idle" {
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
		p.mu.Lock()
		if p.Status != StatusUntrusted {
			r.onlineCount.Add(-1)
			for _, m := range p.Models {
				r.modelProviderDec(m.ID)
			}
		}
		p.mu.Unlock()
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
	r.mu.Lock()
	p, ok := r.providers[providerID]
	if !ok {
		r.mu.Unlock()
		return
	}

	p.mu.Lock()
	if p.Status != StatusUntrusted {
		r.onlineCount.Add(-1)
		for _, m := range p.Models {
			r.modelProviderDec(m.ID)
		}
	}
	p.Status = StatusUntrusted
	p.mu.Unlock()
	r.mu.Unlock()

	r.logger.Warn("provider marked as untrusted",
		"provider_id", providerID,
		"failed_challenges", p.FailedChallenges,
	)
}

func (r *Registry) ForceTrustProvider(providerID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Status = StatusOnline
	p.TrustLevel = TrustSelfSigned
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.FailedChallenges = 0
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	if p.PrivacyCapabilities == nil {
		p.PrivacyCapabilities = &protocol.PrivacyCapabilities{}
	}
	p.PrivacyCapabilities.TextBackendInprocess = true
	p.PrivacyCapabilities.TextProxyDisabled = true
	p.PrivacyCapabilities.PythonRuntimeLocked = true
	p.PrivacyCapabilities.DangerousModulesBlocked = true
	p.PrivacyCapabilities.AntiDebugEnabled = true
	p.PrivacyCapabilities.CoreDumpsDisabled = true
	p.PrivacyCapabilities.EnvScrubbed = true
	p.mu.Unlock()

	r.drainQueuedRequestsForModels(providerModelIDs(p))
	r.logger.Info("provider force-trusted for testing",
		"provider_id", providerID,
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
	if !p.ChallengeVerifiedSIP {
		p.ChallengeVerifiedSIP = true
	}
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
	// Any failed or missing challenge result invalidates the previous
	// coordinator-verified security posture until the provider proves it again.
	p.LastChallengeVerified = time.Time{}
	p.ChallengeVerifiedSIP = false
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
	// Uses a positive provider-reported slot cap when present, otherwise the
	// legacy provider-level dynamic max.
	p.mu.Lock()
	maxConc := p.maxConcurrencyForModelLocked(model)
	pending := float64(p.pendingLoadForModelLocked(model))
	p.mu.Unlock()
	load := pending / float64(maxConc)
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
	backendCap := p.BackendCapacity
	p.mu.Unlock()

	// Base decode TPS — when not reported by the provider, estimate from
	// hardware memory bandwidth using sqrt scaling. Linear bandwidth
	// ratios (e.g. 546 vs 300 = 1.8x) create too much routing skew;
	// sqrt dampens this to ~1.35x, giving faster hardware a mild
	// preference while still distributing load across all providers.
	if decodeTPS <= 0 {
		bw := float64(p.Hardware.MemoryBandwidthGBs)
		if bw > 0 {
			decodeTPS = math.Sqrt(bw) // sqrt scaling: 546→23.4, 400→20, 300→17.3, 150→12.2
		} else {
			decodeTPS = 1.0
		}
	}

	trustMul := TrustMultiplier(trustLevel)

	// Warm model bonus: only applies when the provider is IDLE (no pending
	// requests). This prevents a warm provider from monopolizing all traffic.
	// Once a warm provider has any pending requests, cold providers compete
	// on equal terms — a 20s parallel cold-start beats waiting in a serial
	// queue behind a single warm provider.
	warmBonus := 1.0
	isIdle := pending == 0
	if isIdle {
		for _, wm := range warmModels {
			if wm == model {
				warmBonus = 1.5
				break
			}
		}
		if currentModel == model {
			warmBonus = 1.5
		}
	}

	// Cold-start / crash penalty: apply regardless of load. These represent
	// providers whose backend is DOWN (not just cold in cache). Loading from
	// idle_shutdown takes ~30s, crashed backends may not recover at all.
	if backendCap != nil {
		for _, slot := range backendCap.Slots {
			if slot.Model == model {
				switch slot.State {
				case "idle_shutdown":
					warmBonus = 0.1
				case "crashed":
					warmBonus = 0.05
				}
				break
			}
		}
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

	// GPU memory pressure from backend capacity: penalize providers with
	// high GPU utilization to prefer those with more headroom.
	if backendCap != nil && backendCap.GPUMemoryActiveGB > 0 {
		totalMem := backendCap.TotalMemoryGB
		if totalMem <= 0 {
			totalMem = float64(p.Hardware.MemoryGB)
		}
		if totalMem > 0 {
			gpuUtil := backendCap.GPUMemoryActiveGB / totalMem
			gpuFactor := 1.0 - (gpuUtil * 0.5) // max 50% penalty at full GPU
			if gpuFactor < 0.1 {
				gpuFactor = 0.1
			}
			healthFactor *= gpuFactor
		}
	}

	return (1.0 - load) * decodeTPS * trustMul * repScore * warmBonus * healthFactor
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
func (r *Registry) FindProviderWithTrust(model string, minTrust TrustLevel, excludeIDs ...string) *Provider {
	r.mu.Lock()
	defer r.mu.Unlock()

	// Build a set of excluded provider IDs for O(1) lookup.
	excludeSet := make(map[string]struct{}, len(excludeIDs))
	for _, id := range excludeIDs {
		excludeSet[id] = struct{}{}
	}

	// Determine effective minimum: max of registry default and per-request
	effectiveMin := r.MinTrustLevel
	if minTrust != "" && trustRank(minTrust) > trustRank(effectiveMin) {
		effectiveMin = minTrust
	}

	// Challenge staleness threshold: providers must have passed a
	// challenge within the last interval + grace period. The challenge
	// interval is 5 minutes, so we allow up to 6 minutes (interval +
	// 1-minute grace) to avoid a gap where providers are unroutable
	// between challenge cycles.
	challengeMaxAge := 6 * time.Minute
	now := time.Now()

	var candidates []*Provider
	for _, p := range r.providers {
		// Skip explicitly excluded providers (failed on previous retry attempts).
		if _, excluded := excludeSet[p.ID]; excluded {
			continue
		}

		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		lastChallenge := p.LastChallengeVerified
		runtimeVerified := p.RuntimeVerified
		privateReady := providerSupportsPrivateTextLocked(p)
		p.mu.Unlock()

		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		if trustRank(trust) < trustRank(effectiveMin) {
			continue
		}
		if !runtimeVerified || !privateReady {
			continue
		}
		if lastChallenge.IsZero() || now.Sub(lastChallenge) > challengeMaxAge {
			continue
		}
		p.mu.Lock()
		hasHeadroom := p.hasConcurrencyHeadroomForModelLocked(model)
		p.mu.Unlock()
		if !hasHeadroom {
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

	// Score all candidates and pick the highest.
	bestIdx := 0
	bestScore := ScoreProvider(candidates[0], model)
	for i := 1; i < len(candidates); i++ {
		s := ScoreProvider(candidates[i], model)
		if s > bestScore {
			bestScore = s
			bestIdx = i
		}
	}

	// When multiple candidates tie for the best score (common when all
	// providers have the same hardware/TPS and load), randomly pick among
	// them to distribute load instead of always picking the first one.
	var ties []*Provider
	for _, c := range candidates {
		if ScoreProvider(c, model) >= bestScore-0.001 {
			ties = append(ties, c)
		}
	}
	var selected *Provider
	if len(ties) > 1 {
		selected = ties[rand.Intn(len(ties))]
	} else {
		selected = candidates[bestIdx]
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
		privateReady := providerSupportsPrivateTextLocked(p)
		p.mu.Unlock()

		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		if !r.trustMeetsMinimum(trust) || !privateReady {
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
// modelProviderInc increments the provider count for a model. Must be called
// with r.mu held.
func (r *Registry) modelProviderInc(model string) {
	r.modelProvidersMu.Lock()
	c, ok := r.modelProviders[model]
	if !ok {
		c = &atomic.Int64{}
		r.modelProviders[model] = c
	}
	r.modelProvidersMu.Unlock()
	c.Add(1)
}

// modelProviderDec decrements the provider count for a model. Must be called
// with r.mu held.
func (r *Registry) modelProviderDec(model string) {
	r.modelProvidersMu.Lock()
	c, ok := r.modelProviders[model]
	r.modelProvidersMu.Unlock()
	if ok {
		v := c.Add(-1)
		if v <= 0 {
			r.modelProvidersMu.Lock()
			delete(r.modelProviders, model)
			r.modelProvidersMu.Unlock()
		}
	}
}

// OnlineCount returns the number of online providers.
func (r *Registry) OnlineCount() int64 {
	return r.onlineCount.Load()
}

// ModelProviderSnapshot returns a snapshot of model_id -> provider count.
func (r *Registry) ModelProviderSnapshot() map[string]int64 {
	r.modelProvidersMu.Lock()
	snap := make(map[string]int64, len(r.modelProviders))
	for model, c := range r.modelProviders {
		if v := c.Load(); v > 0 {
			snap[model] = v
		}
	}
	r.modelProvidersMu.Unlock()
	return snap
}

// ProviderCountByChip returns a map of chip_name -> count of online providers.
func (r *Registry) ProviderCountByChip() map[string]int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	counts := make(map[string]int)
	for _, p := range r.providers {
		p.mu.Lock()
		online := p.Status != StatusOffline && p.Status != StatusUntrusted
		p.mu.Unlock()
		if online {
			chip := p.Hardware.ChipName
			if chip == "" {
				chip = "unknown"
			}
			counts[chip]++
		}
	}
	return counts
}

// ModelProviderCounts returns a map of model_id -> count of online providers
// serving that model.
func (r *Registry) ModelProviderCounts() map[string]int {
	snap := r.ModelProviderSnapshot()
	out := make(map[string]int, len(snap))
	for k, v := range snap {
		out[k] = int(v)
	}
	return out
}

func (r *Registry) ProviderCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.providers)
}

func (r *Registry) ProviderCountByVersion() map[string]int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	counts := make(map[string]int)
	for _, p := range r.providers {
		p.mu.Lock()
		online := p.Status != StatusOffline && p.Status != StatusUntrusted
		p.mu.Unlock()
		if !online {
			continue
		}
		ver := p.Version
		if ver == "" {
			ver = "unknown"
		}
		counts[ver]++
	}
	return counts
}

// FleetSnapshot is the read-only summary used by metrics polling. We
// don't lock individual providers — counts may be off-by-one under
// heavy churn — that's acceptable for gauges.
type FleetSnapshot struct {
	Connected  int
	Idle       int
	QueueDepth int
}

// Snapshot returns aggregate counts for /metrics gauges. Cheap enough
// to call every few seconds. Takes the registry's read lock for the
// outer iteration AND each provider's mutex briefly to read Status and
// pending count — those fields are written under p.mu elsewhere
// (Heartbeat, AddPending, RemovePending), so reading them without
// p.mu is a data race even if the gauge value is only advisory.
func (r *Registry) Snapshot() FleetSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	idle := 0
	for _, p := range r.providers {
		p.mu.Lock()
		isIdle := p.Status == StatusOnline && len(p.pendingReqs) == 0
		p.mu.Unlock()
		if isIdle {
			idle++
		}
	}
	q := 0
	if r.queue != nil {
		q = r.queue.TotalSize()
	}
	return FleetSnapshot{
		Connected:  len(r.providers),
		Idle:       idle,
		QueueDepth: q,
	}
}

// ModelCapacity describes the live capacity for a single model.
type ModelCapacity struct {
	ModelID              string  `json:"id"`
	Ready                bool    `json:"ready"`                  // at least one routable provider with headroom
	CanAccept            bool    `json:"can_accept"`             // ready AND queue not full
	RoutableProviders    int     `json:"routable_providers"`     // passed all gates
	WarmProviders        int     `json:"warm_providers"`         // model loaded (slot state "running")
	ColdProviders        int     `json:"cold_providers"`         // model available but not loaded
	ActiveRequests       int     `json:"active_requests"`        // in-flight across fleet
	QueuedRequests       int     `json:"queued_requests"`        // waiting in coordinator queue
	QueueLimit           int     `json:"queue_limit"`            // max queue depth per model
	AggregateTPS         float64 `json:"aggregate_tps"`          // sum of effective decode TPS
	EstimatedTTFTMs      int64   `json:"estimated_ttft_ms"`      // best-case TTFT from lowest-cost warm provider
	TokenBudgetRemaining int64   `json:"token_budget_remaining"` // aggregate free budget across providers
	TokenBudgetTotal     int64   `json:"token_budget_total"`     // aggregate total budget
}

// providerCapSnap is a per-provider snapshot collected under the registry
// lock, then aggregated into ModelCapacity outside the lock.
type providerCapSnap struct {
	model                 string
	warm                  bool
	hasHeadroom           bool // pending < maxConcurrency
	effectiveTPS          float64
	prefillTPS            float64
	activeRequests        int // numRunning + numWaiting from backend slot, or pendingCount
	backlogTokens         float64
	activeTokenBudgetMax  int64
	activeTokenBudgetUsed int64
	queuedTokenBudget     int64
}

// ModelCapacitySnapshot returns a capacity snapshot for every model served
// by at least one provider. Providers must pass the same routing gates as
// snapshotProviderLocked (status, trust, runtime, privacy, challenge
// freshness, concurrency headroom) to be counted as routable.
func (r *Registry) ModelCapacitySnapshot() []ModelCapacity {
	now := time.Now()

	// Phase 1: collect per-provider snapshots under the lock.
	var snaps []providerCapSnap

	r.mu.RLock()
	for _, p := range r.providers {
		p.mu.Lock()

		// Apply the same gates as snapshotProviderLocked.
		if p.Status == StatusOffline || p.Status == StatusUntrusted {
			p.mu.Unlock()
			continue
		}
		if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
			p.mu.Unlock()
			continue
		}
		if !p.RuntimeVerified {
			p.mu.Unlock()
			continue
		}
		if !providerSupportsPrivateTextLocked(p) {
			p.mu.Unlock()
			continue
		}
		if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
			p.mu.Unlock()
			continue
		}

		decodeTPS := resolvedDecodeTPS(p)
		prefillTPS := resolvedPrefillTPS(p)

		// Enumerate every model this provider serves.
		for _, m := range p.Models {
			hasHeadroom := p.hasConcurrencyHeadroomForModelLocked(m.ID)
			// Count only pending requests for this specific model, not the
			// total across all models. Using the total inflates
			// activeRequests for multi-model providers.
			modelPending := 0
			for _, pr := range p.pendingReqs {
				if pr.Model == m.ID {
					modelPending++
				}
			}

			snap := providerCapSnap{
				model:          m.ID,
				hasHeadroom:    hasHeadroom,
				effectiveTPS:   decodeTPS,
				prefillTPS:     prefillTPS,
				activeRequests: modelPending,
			}

			// Check backend capacity for this model's slot.
			if p.BackendCapacity != nil {
				for _, slot := range p.BackendCapacity.Slots {
					if slot.Model != m.ID {
						continue
					}
					snap.warm = slot.State == "running"
					slotActive := int(slot.NumRunning) + int(slot.NumWaiting)
					if slotActive > snap.activeRequests {
						snap.activeRequests = slotActive
					}
					if slot.ObservedDecodeTPS > 0 {
						snap.effectiveTPS = slot.ObservedDecodeTPS
					}
					snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
					snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
					snap.queuedTokenBudget = slot.QueuedTokenBudget
					snap.backlogTokens = float64(slot.MaxTokensPotential)
					break
				}
			} else {
				// Without backend capacity, warm if currently serving this model.
				snap.warm = p.CurrentModel == m.ID
			}

			snaps = append(snaps, snap)
		}
		p.mu.Unlock()
	}
	r.mu.RUnlock()

	// Phase 2: aggregate per-model outside the lock.
	type modelAgg struct {
		routable         int
		warm             int
		cold             int
		activeRequests   int
		aggregateTPS     float64
		budgetRemaining  int64
		budgetTotal      int64
		bestWarmTTFTMs   int64 // -1 = not set
		bestColdTTFTMs   int64 // -1 = not set
		anyImmediateSlot bool  // at least one provider with headroom
	}
	agg := make(map[string]*modelAgg)
	for _, s := range snaps {
		a, ok := agg[s.model]
		if !ok {
			a = &modelAgg{bestWarmTTFTMs: -1, bestColdTTFTMs: -1}
			agg[s.model] = a
		}
		if s.warm {
			a.warm++
		} else {
			a.cold++
		}
		a.activeRequests += s.activeRequests
		a.aggregateTPS += s.effectiveTPS
		if s.activeTokenBudgetMax > 0 {
			headroom := s.activeTokenBudgetMax - s.activeTokenBudgetUsed - s.queuedTokenBudget
			if headroom < 0 {
				headroom = 0
			}
			a.budgetRemaining += headroom
			a.budgetTotal += s.activeTokenBudgetMax
		}
		// Routable providers require both concurrency headroom AND token-budget
		// headroom. A provider with exhausted token budget should not make the
		// model appear immediately ready.
		hasBudgetHeadroom := s.activeTokenBudgetMax <= 0 ||
			s.activeTokenBudgetUsed+s.queuedTokenBudget < s.activeTokenBudgetMax
		if s.hasHeadroom && hasBudgetHeadroom {
			a.routable++
			a.anyImmediateSlot = true
		}

		// Estimate TTFT for this provider: prefill 500 tokens + backlog drain.
		const defaultPromptTokens = 500
		ttftMs := int64(0)
		if s.prefillTPS > 0 {
			ttftMs = int64(float64(defaultPromptTokens) / s.prefillTPS * 1000)
		}
		if s.effectiveTPS > 0 {
			ttftMs += int64(s.backlogTokens / s.effectiveTPS * 1000)
		}
		if s.warm {
			if a.bestWarmTTFTMs < 0 || ttftMs < a.bestWarmTTFTMs {
				a.bestWarmTTFTMs = ttftMs
			}
		} else {
			coldTTFT := ttftMs + 20_000 // 20s cold-start penalty
			if a.bestColdTTFTMs < 0 || coldTTFT < a.bestColdTTFTMs {
				a.bestColdTTFTMs = coldTTFT
			}
		}
	}

	// Phase 3: read queue sizes (separate lock, safe to call after releasing r.mu).
	queueLimit := 0
	if r.queue != nil {
		queueLimit = r.queue.MaxSize()
	}

	result := make([]ModelCapacity, 0, len(agg))
	for model, a := range agg {
		queued := 0
		if r.queue != nil {
			queued = r.queue.QueueSize(model)
		}
		ready := a.routable > 0
		canAccept := ready && (queued < queueLimit || a.anyImmediateSlot)

		ttft := a.bestWarmTTFTMs
		if ttft < 0 {
			ttft = a.bestColdTTFTMs
		}
		if ttft < 0 {
			ttft = 0
		}

		result = append(result, ModelCapacity{
			ModelID:              model,
			Ready:                ready,
			CanAccept:            canAccept,
			RoutableProviders:    a.routable,
			WarmProviders:        a.warm,
			ColdProviders:        a.cold,
			ActiveRequests:       a.activeRequests,
			QueuedRequests:       queued,
			QueueLimit:           queueLimit,
			AggregateTPS:         a.aggregateTPS,
			EstimatedTTFTMs:      ttft,
			TokenBudgetRemaining: a.budgetRemaining,
			TokenBudgetTotal:     a.budgetTotal,
		})
	}
	return result
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
	saferun.Go(r.logger, "registry.evictionLoop", func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r.evictStale(timeout)
			}
		}
	})
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
