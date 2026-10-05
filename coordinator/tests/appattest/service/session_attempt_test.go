package service_test

import (
	"context"
	"errors"
	"slices"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
)

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
