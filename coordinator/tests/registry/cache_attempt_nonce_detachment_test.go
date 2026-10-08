package registry_test

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
			tracker := newReceiptKernelFixture(time.Minute, 2)
			attempts, ledger := tracker.config.Attempts, tracker.config.AttemptBudget
			capability := testV2Capability("11111111-1111-1111-1111-111111111111")
			prompt := exactTestAnchor(16, "c")
			nonce := "fixture-nonce-" + update
			receiptTestAttempt(tracker.Tracker, nonce, capability, prompt)
			if update == "memory_ready" {
				attempt := attempts.Lookup(nonce)
				attempt.MemoryCapability = capability
				admitted := tracker.StoreAttemptLocked(nonce, attempt)
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
				lookup := fenceTestV2Lookup(value, capability, prompt, 1)
				lookup.Tier = tier
				result := tracker.lookup(capability, lookup, routeKey, time.Now())
				if !result.Accepted {
					t.Fatalf("lookup fixture rejected: %s", result.Reason)
				}
			}
			if update == "ssd_ready" || update == "memory_ready" {
				applyLookup(nonce)
			}
			before := ledger.Bytes()
			charge := attempts.Lookup(nonce).AccountedBytes
			if before == 0 || before != charge {
				t.Fatal("fixture did not retain exactly one charged attempt")
			}

			backing := strings.Repeat("x", 1<<20) + nonce
			callerNonce := backing[len(backing)-len(nonce):]
			switch update {
			case "lookup":
				applyLookup(callerNonce)
			case "ssd_ready", "memory_ready":
				ready := fenceTestV2Ready(callerNonce, capability, prompt, 2)
				ready.Tier = tier
				result := tracker.ready(capability, ready, routeKey, time.Now())
				if !result.Accepted {
					t.Fatalf("READY fixture rejected: %s", result.Reason)
				}
			case "terminal":
				tracker.MarkAttemptTerminal(callerNonce, time.Now())
			}

			if attempts.Len() != 1 || ledger.Bytes() != before || attempts.Lookup(nonce).AccountedBytes != charge {
				t.Fatal("accepted update changed record count or immutable logical charge")
			}
			for retainedNonce := range attempts.Entries() {
				if retainedNonce != nonce {
					t.Error("retained nonce bytes changed")
				}
				if unsafe.StringData(retainedNonce) == unsafe.StringData(callerNonce) {
					t.Error("accepted update retained caller's large nonce backing allocation as map key")
				}
			}
			tracker.RemoveAttemptLocked(nonce)
			tracker.RemoveAttemptLocked(callerNonce)
			if ledger.Bytes() != 0 || attempts.Len() != 0 {
				t.Error("updated attempt did not refund exactly once")
			}
		})
	}
}
