package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	cohort "github.com/eigeninference/d-inference/coordinator/internal/appattest/cohort"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/evidence"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/input"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/inventory"
	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// One bounded inbox/worker per negotiated connection; the read loop never waits
// for Apple, database, or cryptography. Serving authorization is a separate opt-in.
type Session struct {
	attestationKey string
	hardware       protocol.Hardware
	admission      input.Admission
	rejectReason   string
	storageScope   *storagebudget.Scope
	integrity      evidence.Integrity
	// The cumulative counter is retained for audit. A later assertion can
	// recover only when that new proof is durably verified without another
	// unarchived input during or after its exchange.
	s                                              *Service
	provider                                       *registry.Provider // read-only legacy comparison snapshot
	in                                             chan protocol.AppAttestShadowPayload
	id, owner, publicKey, version, osVersion, chip string
	key                                            *store.AppAttestShadowKey
	challenge, expected                            string
	started                                        time.Time
	verifier                                       *appattest.Verifier
	store                                          store.AppAttestShadowStore
	archive                                        store.AppAttestArchiveStore
	inventory                                      *inventory.Session
	account                                        string
	protocolVersion                                int
	lastOutcome                                    string
	assertionAt                                    time.Time
	policyFields                                   map[string]any
	authorizationResult                            string // bounded result of the last verified assertion's serving transition
	identity                                       *authorization.Identity
	// Worker-owned dead-key rotation state: set when this exchange sent attest
	// for an already accepted key; cleared before every attempt.
	rotation *recovery.Rotation
	// Sanitized runtime diagnostics from this attempt's ready reply, retained
	// in later proof evidence contexts of the same attempt.
	readyDiagnostics map[string]any
}

func (s *Service) startAppAttestShadow(ctx context.Context, provider *registry.Provider, registration *protocol.RegisterMessage, authenticatedAccount ...string) *Session {
	account := ""
	if len(authenticatedAccount) > 0 {
		account = authenticatedAccount[0]
	}
	inventory := s.startMachineInventory(ctx, provider, registration, account)
	if !s.config.Enabled && !s.config.ServingEnabled {
		return nil
	}
	var nonce [32]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil
	}
	provider.Mu().Lock()
	owner := account
	attestationKey := ""
	publicKey := provider.PublicKey
	if provider.AttestationResult != nil {
		owner += ":" + provider.AttestationResult.PublicKey
		if provider.AttestationResult.Valid && provider.AttestationResult.EncryptionPublicKey == publicKey {
			attestationKey = provider.AttestationResult.PublicKey
		}
	}
	provider.Mu().Unlock()
	hash := sha256.Sum256([]byte(owner))
	x := &Session{s: s, provider: provider, inventory: inventory, account: account, protocolVersion: registration.AppAttestProtocol, hardware: registration.Hardware, attestationKey: attestationKey, in: make(chan protocol.AppAttestShadowPayload, 2),
		id: base64.StdEncoding.EncodeToString(nonce[:]), owner: hex.EncodeToString(hash[:]),
		publicKey: publicKey, version: registration.Version,
		chip:     registration.Hardware.ChipName,
		verifier: appattest.New(appattest.Policy{AppID: s.config.AppID, Environment: s.config.Environment}),
	}
	// Registry.Register clears invalid endpoint keys. Never retain the original
	// registration field here. Require its canonical bounded encoding too:
	// base64 decoders accept arbitrarily many embedded CR/LF characters.
	if _, valid := transcript.Endpoint(publicKey); !valid {
		x.observe("prepare", "encryption_key", nil)
		return nil
	}
	var platform struct {
		Attestation struct {
			OSVersion string `json:"osVersion"`
		} `json:"attestation"`
	}
	_ = json.Unmarshal(registration.Attestation, &platform)
	x.osVersion = platform.Attestation.OSVersion

	// Only protocol 3 is served. It shipped in v0.9.4 together with the
	// callback-timer fix; protocol 2 shipped only in the unsafe v0.9.3,
	// protocol 1 was never released, and older providers send none. A
	// provider that announces an older protocol is a straggler to upgrade.
	if registration.AppAttestProtocol != 3 {
		if registration.AppAttestProtocol != 0 {
			x.observe("rollout", "provider_upgrade_required", nil)
		}
		return nil
	}
	if s.config.Environment != "production" && s.config.Environment != "development" || s.config.AppID == "" {
		x.observe("prepare", "configuration_error", nil)
		return nil
	}
	var ok bool
	x.store, ok = store.As[store.AppAttestShadowStore](s.store)
	if !ok {
		x.observe("prepare", "storage_unavailable", nil)
		return nil
	}
	if inventory != nil {
		inventory.TrackDropped(x.integrity.Dropped)
	}
	x.archive, ok = store.As[store.AppAttestArchiveStore](s.store)
	if !ok || inventory == nil {
		x.observe("prepare", "archive_unavailable", nil)
		return nil
	}
	saferun.Go(s.logger, "appAttestShadow", func() {
		defer x.closeAndArchivePending()
		select {
		case <-ctx.Done():
			return
		case <-inventory.Ready():
		}
		if inventory.Identity().ID == "" {
			x.observe("prepare", "inventory_unavailable", nil)
			return
		}
		x.observe("registration", "observed", nil)
		if decision := cohort.Enrollment(x.account, inventory.Identity().ID, s.config.RolloutPercent); decision != "enabled" {
			x.observe("rollout", decision, nil)
			return
		}
		owner := sha256.Sum256([]byte("machine-owner-v1:" + x.account + ":" + inventory.Identity().ID))
		x.owner = hex.EncodeToString(owner[:])
		x.run(ctx)
	})
	s.sendAppAttestAuthorizationStatus(provider)
	return x
}

func (x *Session) offer(p protocol.AppAttestShadowPayload) {
	x.admission.Offer(p, x.in, x.markDropped)
}

// An input we could not archive may contain a newer assertion or a negative
// security result. Fence the prior App Attest lease immediately; only a new
// durably verified assertion may recover it. Legacy authorization is separate.
func (x *Session) markDropped() {
	if x.s != nil && x.s.authorizer != nil && x.provider != nil {
		// Serialize the counter with apply's final check and registry grant.
		// Incrementing before acquiring a.mu would let a concurrent apply
		// grant after the gap was already visible but before forget fenced it.
		x.integrity.Drop(x.s.authorizer, x.provider)
		return
	}
	x.integrity.Drop(nil, nil)
}

func (x *Session) runAttempt(ctx context.Context) {
	// Spread onboarding so a coordinator restart does not synchronize Apple calls.
	var jitter [1]byte
	_, _ = rand.Read(jitter[:])
	timer := time.NewTimer(time.Duration(jitter[0]%30) * time.Second)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		x.observe("prepare", "disconnected", nil)
		return
	case <-timer.C:
	}
	if !x.send(ctx, "prepare") {
		return
	}
	timer.Reset(recovery.ResponseTimeout)
	for {
		select {
		case <-ctx.Done():
			if x.expected != "" {
				x.observe(x.expected, "disconnected", nil)
			}
			return
		case <-timer.C:
			if x.expected != "" {
				x.observe(x.expected, "timeout", nil)
				return
			}
			if !x.send(ctx, "assert") {
				return
			}
			timer.Reset(recovery.ResponseTimeout)
		case reply := <-x.in:
			if x.expected == "" && reply.Session == x.id {
				// During the assertion interval, archive an unsolicited
				// duplicate without stopping or resetting the timer. A failed
				// archive instead fences the prior lease and retries fresh.
				if !x.archiveUnsolicitedReply(ctx, reply) {
					return
				}
				continue
			}
			if reply.Session != x.id {
				// A callback from a timed-out attempt cannot stop or satisfy the
				// current exchange. Retain it without moving the current timer;
				// an archive failure fences the old proof and retries fresh.
				if !x.archiveUnsolicitedReply(ctx, reply) {
					return
				}
				continue
			}
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			// Global non-blocking concurrency bound: a busy verifier is an observation,
			// never backpressure on the authoritative path.
			select {
			case x.s.verifierSlots <- struct{}{}:
			default:
				x.rejectReason = "verifier_busy"
				operation, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				x.handle(operation, reply)
				cancel()
				return
			}
			next := func() string {
				defer func() { <-x.s.verifierSlots }()
				operation, cancel := context.WithTimeout(ctx, 2*time.Second)
				defer cancel()
				return x.handle(operation, reply)
			}()
			if next == "stop" {
				return
			}
			if next == "wait" {
				x.expected = ""
				timer.Reset(x.nextAssertionDelay())
				continue
			}
			if !x.send(ctx, next) {
				return
			}
			timer.Reset(recovery.ResponseTimeout)
		}
	}
}

// The active challenge timer belongs to the current session, so a late frame
// only consumes archive capacity. When that archive fails, the older lease was
// already fenced by markDropped and a new exchange must be scheduled.
func (x *Session) archiveUnsolicitedReply(ctx context.Context, reply protocol.AppAttestShadowPayload) bool {
	keep, result := x.pipeline().RetainUnsolicited(ctx, x.pendingAttempt(), reply)
	x.lastOutcome = result.Outcome
	return keep
}
