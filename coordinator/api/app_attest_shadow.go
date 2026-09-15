package api

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const shadowResponseTimeout = 90 * time.Second
const shadowAssertionInterval = 10 * time.Minute

// One bounded inbox/worker per negotiated connection; the read loop never waits
// for Apple, database, or cryptography. No method on this type changes trust.
type appAttestShadowSession struct {
	offerMu                                        sync.Mutex
	rejectReason                                   string
	storageSlotHeld                                bool // owned by the serialized session worker
	closed                                         atomic.Bool
	dropped                                        atomic.Uint64
	s                                              *Server
	provider                                       *registry.Provider // read-only legacy comparison snapshot
	in                                             chan protocol.AppAttestShadowPayload
	id, owner, publicKey, version, osVersion, chip string
	key                                            *store.AppAttestShadowKey
	challenge, expected                            string
	started                                        time.Time
	verifier                                       *appattest.Verifier
	store                                          store.AppAttestShadowStore
	archive                                        store.AppAttestArchiveStore
	inventory                                      *machineInventorySession
	account                                        string
	protocolVersion                                int
	evidenceID                                     string
	evidenceOutcome                                string
}

func (s *Server) startAppAttestShadow(ctx context.Context, provider *registry.Provider, registration *protocol.RegisterMessage, authenticatedAccount ...string) *appAttestShadowSession {
	account := ""
	if len(authenticatedAccount) > 0 {
		account = authenticatedAccount[0]
	}
	inventory := s.startMachineInventory(ctx, provider, registration, account)
	if !s.appAttestShadow.Enabled {
		return nil
	}
	var nonce [32]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil
	}
	provider.Mu().Lock()
	owner := account
	if provider.AttestationResult != nil {
		owner += ":" + provider.AttestationResult.PublicKey
	}
	provider.Mu().Unlock()
	hash := sha256.Sum256([]byte(owner))
	x := &appAttestShadowSession{s: s, provider: provider, inventory: inventory, account: account, protocolVersion: registration.AppAttestProtocol, in: make(chan protocol.AppAttestShadowPayload, 2),
		id: base64.StdEncoding.EncodeToString(nonce[:]), owner: hex.EncodeToString(hash[:]),
		publicKey: registration.PublicKey, version: registration.Version,
		chip:     registration.Hardware.ChipName,
		verifier: appattest.New(appattest.Policy{AppID: s.appAttestShadow.AppID, Environment: s.appAttestShadow.Environment}),
	}
	var platform struct {
		Attestation struct {
			OSVersion string `json:"osVersion"`
		} `json:"attestation"`
	}
	_ = json.Unmarshal(registration.Attestation, &platform)
	x.osVersion = platform.Attestation.OSVersion

	if registration.AppAttestProtocol != 1 && registration.AppAttestProtocol != 2 {

		return nil
	}
	if s.appAttestShadow.Environment != "production" && s.appAttestShadow.Environment != "development" || s.appAttestShadow.AppID == "" {
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
		inventory.mu.Lock()
		inventory.dropped = x.dropped.Load
		inventory.mu.Unlock()
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
		case <-inventory.ready:
		}
		if inventory.snapshot().ID == "" {
			x.observe("prepare", "inventory_unavailable", nil)
			return
		}
		x.observe("registration", "observed", nil)
		if x.protocolVersion == 2 {
			owner := sha256.Sum256([]byte("machine-owner-v1:" + x.account + ":" + inventory.snapshot().ID))
			x.owner = hex.EncodeToString(owner[:])
		}
		x.run(ctx)
	})
	return x
}

func (x *appAttestShadowSession) offer(p protocol.AppAttestShadowPayload) {
	x.offerMu.Lock()
	defer x.offerMu.Unlock()
	if x.closed.Load() {
		x.dropped.Add(1)
		return
	}
	// Length bounds also cover decode-only fields; oversized proofs never queue.
	if len(p.Action) > 32 || len(p.Environment) > 32 || len(p.AccountScope) > 64 || len(p.EnrollmentSession) > 64 || len(p.KeyID) > 64 || len(p.Challenge) > 64 || len(p.Session) > 64 || len(p.Proof) > 44*1024 || len(p.Result) > 64 {
		x.dropped.Add(1)
		return
	}
	for _, value := range p.Status.Values() {
		if len(value) > 128 {
			x.dropped.Add(1)
			return
		}
	}
	select {
	case x.in <- p:
	default:
		x.dropped.Add(1)
	}
}

func (x *appAttestShadowSession) run(ctx context.Context) {
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
	timer.Reset(shadowResponseTimeout)
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
			timer.Reset(shadowResponseTimeout)
		case reply := <-x.in:
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			// Global non-blocking concurrency bound: a busy verifier is an observation,
			// never backpressure on the authoritative path.
			select {
			case x.s.appAttestShadowSlots <- struct{}{}:
			default:
				x.rejectReason = "verifier_busy"
				operation, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				x.handle(operation, reply)
				cancel()
				return
			}
			next := func() string {
				defer func() { <-x.s.appAttestShadowSlots }()
				operation, cancel := context.WithTimeout(ctx, 2*time.Second)
				defer cancel()
				return x.handle(operation, reply)
			}()
			if next == "stop" {
				return
			}
			if next == "wait" {
				x.expected = ""
				timer.Reset(shadowAssertionInterval)
				continue
			}
			if !x.send(ctx, next) {
				return
			}
			timer.Reset(shadowResponseTimeout)
		}
	}
}
