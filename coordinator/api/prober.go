package api

// Base-rewards correctness prober (design §6 gate 5, Phase 1).
//
// At zero organic demand a provider can't prove willingness-to-serve through
// real jobs, so the coordinator periodically originates its own inference
// request — encrypted to the provider exactly like a consumer's — and records
// whether the machine returned a valid, SE-signed completion. That probe result
// is the OTHER half of the work-gate (the engine accepts a billed job OR a
// passed probe within the rolling window).
//
// What ships here (and what doesn't): the probe proves liveness + capacity (a
// real, SE-signed, non-empty completion on the loaded model) and is recorded
// for the gate. Byte-exact known-answer verification (precomputing the expected
// ResponseHash) is a documented follow-up — it needs the Swift/Go hash domains
// confirmed identical and expected hashes pinned per (weight_hash, MLX version).
// Until then ExpectedHash is left empty and Success means "valid signed
// completion arrived in time", not "bytes matched".
//
// SAFETY: the whole prober is gated behind EIGENINFERENCE_BASE_REWARDS (off by
// default) and launched only from main when the engine is enabled. Probe
// requests set FreeSelfRoute so they never create an earning row or a payout —
// Model is irrelevant to billing here, and §2.8's earnings filters exclude
// model='probe' regardless.

import (
	"context"
	cryptorand "crypto/rand"
	"encoding/json"
	"math/big"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

const (
	// probeOuterInterval is the coarse cadence at which the prober wakes and
	// probabilistically selects providers to probe. Actual probes fire at
	// random offsets so a provider can't special-case a fixed schedule.
	probeOuterInterval = 12 * time.Minute
	// probeTimeout bounds a single probe round-trip.
	probeTimeout = 45 * time.Second
	// probeMaxTokens keeps probe cost negligible.
	probeMaxTokens = 8
	// probePerProviderChance is the per-tick probability each eligible provider
	// is probed, so probes land at random times within an epoch.
	probePerProviderChance = 0.25
	// probePrompt is a tiny deterministic prompt (temperature 0).
	probePrompt = "Reply with the single word: ok"
)

// Prober periodically probes eligible providers to prove willingness-to-serve.
type Prober struct {
	srv *Server
	rng func() float64 // injectable [0,1) source (defaults to crypto-backed jitter)
}

// NewProber constructs a Prober bound to the server. It is inert until Run is
// called (which main only does when base rewards are enabled).
func NewProber(s *Server) *Prober {
	return &Prober{srv: s, rng: proberJitter}
}

// Run drives the probe loop until ctx is cancelled. Launch via saferun.Go so a
// panic never crashes the coordinator.
func (p *Prober) Run(ctx context.Context) {
	ticker := time.NewTicker(probeOuterInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.tick(ctx)
		}
	}
}

// tick probes a random subset of eligible providers.
func (p *Prober) tick(ctx context.Context) {
	for _, snap := range p.srv.registry.ListProviders() {
		if !snap.Attested || !snap.Online || snap.CurrentModel == "" || snap.SerialNumber == "" {
			continue
		}
		if p.rng() > probePerProviderChance {
			continue
		}
		p.probeProvider(ctx, snap)
	}
}

// probeProvider sends one encrypted probe to a specific provider (pinned by
// serial) and records the outcome. Failures are recorded too (success=false)
// so a provider that stops answering loses the probe half of its work-gate.
func (p *Prober) probeProvider(ctx context.Context, snap registry.ProviderSnapshot) {
	s := p.srv
	model := snap.CurrentModel
	result := &store.ProbeResult{
		ProviderKey: snap.ProviderKey,
		ProviderID:  snap.ID,
		Model:       "probe", // tag so earnings filters never count probe traffic
	}

	body, err := json.Marshal(map[string]any{
		"model":       model,
		"messages":    []map[string]string{{"role": "user", "content": probePrompt}},
		"temperature": 0,
		"max_tokens":  probeMaxTokens,
		"stream":      false,
	})
	if err != nil {
		p.record(result, false, 0, "")
		return
	}

	requestID := uuid.New().String()
	pr := &registry.PendingRequest{
		RequestID:              requestID,
		Model:                  model,
		ConsumerKey:            "base-rewards-probe",
		AllowedProviderSerials: []string{snap.SerialNumber}, // pin to this machine
		// FreeSelfRoute makes the dispatch settle free (no earning row, no payout).
		// We deliberately do NOT set SelfRouteOnly: that flag means "owned-only"
		// and, with no OwnerAccountID, ReserveProviderEx would filter out every
		// provider (providerOwnedBy == false), so the probe could never reserve
		// the pinned machine. The serial allowlist alone does the pinning.
		FreeSelfRoute:         true,
		EstimatedPromptTokens: 8,
		RequestedMaxTokens:    probeMaxTokens,
		AcceptedCh:            make(chan struct{}, 1),
		ChunkCh:               make(chan string, chunkBufferSize),
		CompleteCh:            make(chan protocol.UsageInfo, 1),
		ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
		Timing:                &registry.RequestTiming{ReceivedAt: time.Now()},
	}

	provider, _ := s.registry.ReserveProviderEx(model, pr)
	if provider == nil || provider.PublicKey == "" || provider.Conn == nil {
		if provider != nil {
			provider.RemovePending(requestID)
			s.registry.SetProviderIdle(provider.ID)
		}
		p.record(result, false, 0, "")
		return
	}
	defer func() {
		provider.RemovePending(requestID)
		s.registry.SetProviderIdle(provider.ID)
	}()

	providerPubKey, err := e2e.ParsePublicKey(provider.PublicKey)
	if err != nil {
		p.record(result, false, 0, "")
		return
	}
	sessionKeys, err := e2e.GenerateSessionKeys()
	if err != nil {
		p.record(result, false, 0, "")
		return
	}
	encrypted, err := e2e.Encrypt(body, providerPubKey, sessionKeys)
	if err != nil {
		p.record(result, false, 0, "")
		return
	}
	pr.SessionPrivKey = &sessionKeys.PrivateKey

	data, err := json.Marshal(map[string]any{
		"type":       protocol.TypeInferenceRequest,
		"request_id": requestID,
		"encrypted_body": map[string]string{
			"ephemeral_public_key": encrypted.EphemeralPublicKey,
			"ciphertext":           encrypted.Ciphertext,
		},
	})
	if err != nil {
		p.record(result, false, 0, "")
		return
	}

	dctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	if err := provider.Conn.Write(dctx, websocket.MessageText, data); err != nil {
		p.record(result, false, 0, "")
		return
	}

	started := time.Now()
	text, _, seSig, respHash, awaitErr := s.awaitCompletion(dctx, pr)
	latencyMs := time.Since(started).Milliseconds()

	// On timeout/error the provider may still be generating the probe completion.
	// Send a cancel so it stops and frees capacity (the deferred RemovePending +
	// SetProviderIdle alone would let an abandoned probe overlap real work).
	if awaitErr != nil {
		s.sendProviderCancel(provider, requestID)
	}

	// Success = a valid, SE-signed, non-empty completion arrived in time.
	// (Byte-exact known-answer matching is a documented follow-up.)
	success := awaitErr == nil && seSig != "" && len(text) > 0
	p.record(result, success, latencyMs, respHash)
}

func (p *Prober) record(result *store.ProbeResult, success bool, latencyMs int64, respHash string) {
	result.Success = success
	result.LatencyMs = latencyMs
	result.ResponseHash = respHash
	if err := p.srv.store.RecordProbeResult(result); err != nil {
		p.srv.logger.Error("base rewards: failed to record probe result",
			"provider_key", result.ProviderKey, "success", success, "error", err)
	}
}

// proberJitter returns a pseudo-random [0,1) from crypto/rand so probe timing is
// not predictable to providers. Scripts/tests can inject a fixed rng.
func proberJitter() float64 {
	const scale = 1_000_000
	n, err := cryptorand.Int(cryptorand.Reader, big.NewInt(scale))
	if err != nil {
		// Extremely unlikely; preserve liveness if system entropy is unavailable.
		return float64(time.Now().UnixNano()%scale) / float64(scale)
	}
	return float64(n.Int64()) / float64(scale)
}
