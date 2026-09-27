package registry

import (
	"strings"
	"testing"
	"time"
	"unsafe"
)

// Updating an existing Go map entry can replace its string key header even
// when the bytes are equal. The logical charge must not mask retention of an
// arbitrarily large caller allocation through a lookup/READY/terminal nonce.
func TestCacheAttemptNonceDetachmentAfterRetainedUpdates(t *testing.T) {
	for _, update := range []string{"lookup", "ssd_ready", "memory_ready", "terminal"} {
		t.Run(update, func(t *testing.T) {
			tracker := newCacheRoutingTracker(time.Minute, 2)
			capability := testV2Capability("11111111-1111-1111-1111-111111111111")
			prompt := exactTestAnchor(16, "c")
			nonce := "fixture-nonce-" + update
			testV2Attempt(tracker, nonce, capability, prompt)
			if update == "memory_ready" {
				tracker.mu.Lock()
				attempt := tracker.attempts[nonce]
				attempt.MemoryCapability = capability
				admitted := tracker.storeAttemptLocked(nonce, attempt)
				tracker.mu.Unlock()
				if !admitted {
					t.Fatal("memory capability fixture replacement refused")
				}
			}
			routeKey := []byte("fixture-route-key")
			tier := "ssd"
			if update == "memory_ready" {
				tier = "memory"
			}
			applyLookup := func(value string) {
				t.Helper()
				lookup := testV2Lookup(value, capability, prompt, 1)
				lookup.Tier = tier
				result := tracker.applyLookupV2Decision("provider", nil, capability, lookup, routeKey, time.Now())
				if !result.Accepted {
					t.Fatalf("lookup fixture rejected: %s", result.Reason)
				}
			}
			if update == "ssd_ready" || update == "memory_ready" {
				applyLookup(nonce)
			}
			tracker.mu.Lock()
			before := tracker.attemptBytes
			charge := tracker.attempts[nonce].accountedBytes
			tracker.mu.Unlock()
			if before == 0 || before != charge {
				t.Fatal("fixture did not retain exactly one charged attempt")
			}

			backing := strings.Repeat("x", 1<<20) + nonce
			callerNonce := backing[len(backing)-len(nonce):]
			switch update {
			case "lookup":
				applyLookup(callerNonce)
			case "ssd_ready", "memory_ready":
				ready := testV2Ready(callerNonce, capability, prompt, 2)
				ready.Tier = tier
				result := tracker.applyReadyV2Decision("provider", nil, capability, ready, routeKey, time.Now())
				if !result.Accepted {
					t.Fatalf("READY fixture rejected: %s", result.Reason)
				}
			case "terminal":
				tracker.markAttemptTerminal(callerNonce, time.Now())
			}

			tracker.mu.Lock()
			defer tracker.mu.Unlock()
			if len(tracker.attempts) != 1 || tracker.attemptBytes != before || tracker.attempts[nonce].accountedBytes != charge {
				t.Fatal("accepted update changed record count or immutable logical charge")
			}
			for retainedNonce := range tracker.attempts {
				if retainedNonce != nonce {
					t.Error("retained nonce bytes changed")
				}
				if unsafe.StringData(retainedNonce) == unsafe.StringData(callerNonce) {
					t.Error("accepted update retained caller's large nonce backing allocation as map key")
				}
			}
			tracker.removeAttemptLocked(nonce)
			tracker.removeAttemptLocked(callerNonce)
			if tracker.attemptBytes != 0 || len(tracker.attempts) != 0 {
				t.Error("updated attempt did not refund exactly once")
			}
		})
	}
}
