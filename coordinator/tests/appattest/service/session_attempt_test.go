package service_test

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"slices"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest/service"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/fxamacker/cbor/v2"
	"nhooyr.io/websocket"
)

func shadowKeyID(fill byte) string {
	return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{fill}, 32))
}

// exchangeHarness runs a real exchange worker, started by StartSession, against
// an in-memory provider socket. The test plays the provider: it reads
// challenges and offers replies.
type exchangeHarness struct {
	x        *service.Session
	mem      *memorystore.MemoryStore
	client   *websocket.Conn
	endpoint *e2e.SessionKeys
	device   *ecdsa.PrivateKey
	keyID    string
	events   eventLog
	metrics  *metricLog
	cancel   context.CancelFunc
}

type exchangeOptions struct {
	// wrap replaces the service store; nil uses the harness memory store.
	wrap func(*memorystore.MemoryStore) store.Store
	// disconnected starts the session for a provider without a writer.
	disconnected bool
}

// startExchange must be called inside a synctest bubble. The harness device key
// is already accepted for the authenticated account, under an owner that
// differs from the session's account-and-machine owner.
func startExchange(t *testing.T, opts exchangeOptions) *exchangeHarness {
	t.Helper()
	h := &exchangeHarness{mem: memorystore.NewMemory(store.Config{}), keyID: shadowKeyID(4), metrics: newMetricLog()}
	var err error
	if h.endpoint, err = e2e.GenerateSessionKeys(); err != nil {
		t.Fatal(err)
	}
	if h.device, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader); err != nil {
		t.Fatal(err)
	}
	h.enroll(t, store.AppAttestShadowKey{KeyID: h.keyID, Owner: "owner", AccountID: "account"})
	endpoint := base64.StdEncoding.EncodeToString(h.endpoint.PublicKey[:])
	var p *registry.Provider
	if opts.disconnected {
		p = newSessionProvider(endpoint, "se")
	} else {
		p, h.client = connectedShadowProvider(t, endpoint)
	}
	var st store.Store = h.mem
	if opts.wrap != nil {
		st = opts.wrap(h.mem)
	}
	ctx, cancel := context.WithCancel(context.Background())
	h.cancel = cancel
	t.Cleanup(cancel)
	s := service.New(ctx, service.Config{Enabled: true, RolloutPercent: 100, AppID: "TEST.app", Environment: "production"},
		service.Dependencies{Store: st, Logger: discardLogger(), Emit: h.events.emit, Metrics: h.metrics.metrics()})
	h.x = s.StartSession(ctx, p, &protocol.RegisterMessage{AppAttestProtocol: 3, Version: "0.9.4", Hardware: protocol.Hardware{ChipName: "Apple M4"}}, "account")
	if h.x == nil {
		t.Fatal("eligible provider got no session")
	}
	return h
}

// enroll stores an accepted credential for the harness device key.
func (h *exchangeHarness) enroll(t *testing.T, key store.AppAttestShadowKey) {
	t.Helper()
	key.AppID, key.Environment, key.PublicKey = "TEST.app", "production", elliptic.Marshal(h.device.Curve, h.device.X, h.device.Y)
	if _, err := h.mem.InsertAppAttestShadowKey(context.Background(), key); err != nil {
		t.Fatal(err)
	}
}

func (h *exchangeHarness) read(t *testing.T) protocol.AppAttestShadowPayload {
	t.Helper()
	_, data, err := h.client.Read(context.Background())
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var m protocol.AppAttestShadowMessage
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	return m.Payload
}

// machineOwner is the owner StartSession binds to the account and the
// machine that inventory observed for this connection.
func (h *exchangeHarness) machineOwner(t *testing.T) (machine, owner string) {
	t.Helper()
	machine, _ = h.events.field("registration", "observed", "machine_id").(string)
	if machine == "" {
		t.Fatal("registration observed without a machine")
	}
	hash := sha256.Sum256([]byte("machine-owner-v1:account:" + machine))
	return machine, hex.EncodeToString(hash[:])
}

func (h *exchangeHarness) ready(session, keyID string) {
	h.x.Offer(protocol.AppAttestShadowPayload{Session: session, Action: "ready", Result: "ok", KeyID: keyID})
}

func (h *exchangeHarness) challenge(t *testing.T, frame protocol.AppAttestShadowPayload) string {
	t.Helper()
	if frame.Action != "assert" || frame.EncryptedChallenge == nil {
		t.Fatalf("expected an encrypted assert challenge, got %+v", frame)
	}
	plain, err := e2e.Decrypt(&e2e.EncryptedPayload{EphemeralPublicKey: frame.EncryptedChallenge.EphemeralPublicKey, Ciphertext: frame.EncryptedChallenge.Ciphertext}, h.endpoint)
	if err != nil {
		t.Fatal(err)
	}
	return string(plain)
}

// assertion signs the challenge the way a provider's App Attest key does.
func (h *exchangeHarness) assertion(t *testing.T, frame protocol.AppAttestShadowPayload, counter byte) protocol.AppAttestShadowPayload {
	t.Helper()
	challenge := h.challenge(t, frame)
	status := &protocol.AppAttestStatus{OSVersion: "27"}
	endpoint := base64.StdEncoding.EncodeToString(h.endpoint.PublicKey[:])
	hash := protocol.AppAttestShadowHashV3("assert", frame.Session, "production", h.keyID, challenge, endpoint, frame.AccountScope, status)
	rp := sha256.Sum256([]byte("TEST.app"))
	auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, counter)
	signed := sha256.Sum256(append(auth, hash[:]...))
	signed = sha256.Sum256(signed[:])
	signature, err := ecdsa.SignASN1(rand.Reader, h.device, signed[:])
	if err != nil {
		t.Fatal(err)
	}
	body, err := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if err != nil {
		t.Fatal(err)
	}
	return protocol.AppAttestShadowPayload{Session: frame.Session, Action: "assertion", Result: "ok", KeyID: h.keyID, Challenge: challenge,
		Proof: base64.StdEncoding.EncodeToString(body), ProtocolVersion: 3, Status: status}
}

func requireOutcomes(t *testing.T, got []string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !slices.Contains(got, w) {
			t.Fatalf("missing %s in %v", w, got)
		}
	}
}

func TestExchangeWorkerAssertsWaitsReassertsAndRecovers(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		h := startExchange(t, exchangeOptions{})
		prepare := h.read(t)
		if prepare.Action != "prepare" || prepare.Session == "" {
			t.Fatalf("prepare frame %+v", prepare)
		}
		// A late callback from an older attempt is archived without ending
		// this exchange.
		h.ready("older-session", h.keyID)
		h.ready(prepare.Session, h.keyID)
		first := h.read(t)
		start := time.Now()
		h.x.Offer(h.assertion(t, first, 1))
		synctest.Wait()
		if key, _ := h.mem.GetAppAttestShadowKey(context.Background(), h.keyID); key == nil || key.Counter != 1 {
			t.Fatalf("verified assertion did not advance the durable counter: %+v", key)
		}
		// During the assertion interval a duplicate of the same session is
		// archived and does not move the next challenge.
		h.ready(prepare.Session, h.keyID)
		second := h.read(t)
		if waited := time.Since(start); waited != recovery.AssertionInterval {
			t.Fatalf("next assertion after %v, want %v", waited, recovery.AssertionInterval)
		}
		if h.challenge(t, second) == h.challenge(t, first) {
			t.Fatal("assertion challenge reused")
		}
		// No reply: the response timer ends the attempt and recovery starts a
		// new session after a short retry delay.
		retry := h.read(t)
		if retry.Action != "prepare" || retry.Session == prepare.Session {
			t.Fatalf("recovery frame %+v", retry)
		}
		h.cancel()
		synctest.Wait()

		requireOutcomes(t, h.events.outcomes(), "protocol:unexpected_reply", "ready:reported_supported", "assertion:verified",
			"assertion:timeout", "recovery:retry_scheduled", "ready:disconnected")
		// Every offered frame was queued; none was counted as an evidence gap.
		if dropped := h.events.field("assertion", "verified", "inbox_dropped"); dropped != uint64(0) {
			t.Fatalf("verified assertion recorded inbox_dropped=%v", dropped)
		}
		if h.metrics.histogram("app_attest.shadow.duration_ms") == 0 {
			t.Fatal("exchange durations not reported")
		}
	})
}

func TestReadyReplyMatchesKeyOwnerOrAuthenticatedAccount(t *testing.T) {
	for _, tc := range []struct {
		name     string
		key      func(machine, owner string) store.AppAttestShadowKey
		accepted bool
	}{
		{"session owner on another account", func(machine, owner string) store.AppAttestShadowKey {
			return store.AppAttestShadowKey{Owner: owner, AccountID: "other", MachineID: machine}
		}, true},
		{"previous owner on the authenticated account", func(string, string) store.AppAttestShadowKey {
			return store.AppAttestShadowKey{Owner: "previous-machine-owner", AccountID: "account"}
		}, true},
		{"another account and owner on this machine", func(machine, _ string) store.AppAttestShadowKey {
			return store.AppAttestShadowKey{Owner: "someone", AccountID: "other", MachineID: machine}
		}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				h := startExchange(t, exchangeOptions{})
				prepare := h.read(t)
				key := tc.key(h.machineOwner(t))
				key.KeyID = shadowKeyID(5)
				h.enroll(t, key)
				h.ready(prepare.Session, key.KeyID)
				if tc.accepted {
					if frame := h.read(t); frame.Action != "assert" || frame.KeyID != key.KeyID {
						t.Fatalf("matching key not challenged: %+v", frame)
					}
				} else {
					synctest.Wait()
					got := h.events.outcomes()
					requireOutcomes(t, got, "ready:key_owner_or_policy")
					if slices.Contains(got, "assert:attempted") || slices.Contains(got, "attest:attempted") {
						t.Fatalf("another account's key was challenged: %v", got)
					}
				}
				h.cancel()
				synctest.Wait()
			})
		})
	}
}

type failingEnrollmentSave struct{ *memorystore.MemoryStore }

func (*failingEnrollmentSave) SaveAppAttestEnrollment(context.Context, store.AppAttestEnrollment) error {
	return errors.New("write failed")
}

func TestExchangeWorkerStopsOnClientFailureAndUnsentChallenge(t *testing.T) {
	t.Run("client reports unsupported", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			h := startExchange(t, exchangeOptions{})
			prepare := h.read(t)
			h.x.Offer(protocol.AppAttestShadowPayload{Session: prepare.Session, Action: "ready", Result: "unsupported"})
			synctest.Wait()
			got := h.events.outcomes()
			requireOutcomes(t, got, "ready:unsupported")
			if slices.Contains(got, "recovery:retry_scheduled") {
				t.Fatalf("unsupported client was retried: %v", got)
			}
			h.cancel()
			synctest.Wait()
		})
	})
	t.Run("next challenge cannot be sent", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			// An unknown key needs attest, whose enrollment write fails.
			h := startExchange(t, exchangeOptions{wrap: func(mem *memorystore.MemoryStore) store.Store { return &failingEnrollmentSave{mem} }})
			prepare := h.read(t)
			h.ready(prepare.Session, shadowKeyID(9))
			synctest.Wait()
			requireOutcomes(t, h.events.outcomes(), "attest:storage_error", "recovery:retry_scheduled")
			h.cancel()
			synctest.Wait()
		})
	})
}

func TestExchangeWorkerObservesDisconnectAndMissingReady(t *testing.T) {
	t.Run("cancelled before first challenge", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			h := startExchange(t, exchangeOptions{})
			// The worker is blocked on its onboarding jitter or, with zero
			// jitter, already sent prepare and waits for ready.
			synctest.Wait()
			h.cancel()
			synctest.Wait()
			got := h.events.outcomes()
			last := got[len(got)-1]
			if last != "prepare:disconnected" && last != "ready:disconnected" || slices.Contains(got, "ready:reported_supported") {
				t.Fatalf("events %v", got)
			}
		})
	})
	t.Run("ready never arrives", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			h := startExchange(t, exchangeOptions{})
			h.read(t)
			time.Sleep(recovery.ResponseTimeout - time.Nanosecond)
			synctest.Wait()
			if slices.Contains(h.events.outcomes(), "ready:timeout") {
				t.Fatal("ready timed out early")
			}
			time.Sleep(time.Nanosecond)
			synctest.Wait()
			requireOutcomes(t, h.events.outcomes(), "ready:timeout")
			h.cancel()
			synctest.Wait()
		})
	})
	t.Run("provider writer stopped", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			h := startExchange(t, exchangeOptions{disconnected: true})
			// Onboarding jitter is below 30 seconds.
			time.Sleep(30 * time.Second)
			synctest.Wait()
			requireOutcomes(t, h.events.outcomes(), "prepare:send_failed")
			h.cancel()
			synctest.Wait()
		})
	})
}
