package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"strings"
	"testing"
	"time"
)

func TestCacheLookupRejectionReasonsPreserveFences(t *testing.T) {
	for _, tc := range []struct {
		name     string
		reason   CacheReceiptReason
		mismatch bool
		change   func(*cacheRoutingTracker, *protocol.PrefixCacheLookupV2Message)
	}{
		{"missing attempt", CacheReceiptAttemptUnavailable, false, func(t *cacheRoutingTracker, m *protocol.PrefixCacheLookupV2Message) { m.CacheReceiptNonce = "unknown" }},
		{"wrong request", CacheReceiptAttemptBinding, false, func(t *cacheRoutingTracker, m *protocol.PrefixCacheLookupV2Message) { m.RequestID = "other" }},
		{"identity", CacheReceiptIdentityMismatch, true, func(t *cacheRoutingTracker, m *protocol.PrefixCacheLookupV2Message) {
			m.ModelAggregateHash = strings.Repeat("f", 64)
		}},
		{"prompt", CacheReceiptPromptMismatch, true, func(t *cacheRoutingTracker, m *protocol.PrefixCacheLookupV2Message) {
			m.PromptAnchor.ChainHash = strings.Repeat("f", 64)
		}},
		{"sequence", CacheReceiptSequence, false, func(t *cacheRoutingTracker, m *protocol.PrefixCacheLookupV2Message) { m.CacheSeq = 0 }},
		{"invalid shape", CacheReceiptInvalid, false, func(t *cacheRoutingTracker, m *protocol.PrefixCacheLookupV2Message) { m.StageMs = -1 }},
		{"duplicate lookup", CacheReceiptDuplicateLookup, false, func(t *cacheRoutingTracker, m *protocol.PrefixCacheLookupV2Message) {
			a := t.attempts[m.CacheReceiptNonce]
			a.LookupSeen = true
			t.attempts[m.CacheReceiptNonce] = a
		}},
		{"capability change", CacheReceiptCapabilityChanged, false, func(t *cacheRoutingTracker, m *protocol.PrefixCacheLookupV2Message) {
			a := t.attempts[m.CacheReceiptNonce]
			a.V2Capability.Ready = false
			t.attempts[m.CacheReceiptNonce] = a
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tracker := newCacheRoutingTracker(time.Minute, 2)
			cap := testV2Capability("11111111-1111-1111-1111-111111111111")
			prompt := protocol.PrefixCacheAnchor{ChainHash: strings.Repeat("c", 64), TokenCount: int(cap.BlockSize)}
			testV2Attempt(tracker, "nonce", cap, prompt)
			msg := testV2Lookup("nonce", cap, prompt, 1)
			tc.change(tracker, msg)
			d := tracker.applyLookupV2Decision("provider", nil, cap, msg, []byte("route"), time.Now())
			if d.Accepted || d.Reason != tc.reason || d.mismatch != tc.mismatch {
				t.Fatalf("decision=%+v", d)
			}
			if tracker.holderCount != 0 {
				t.Fatal("rejected receipt created a holder")
			}
		})
	}
}

func TestCacheReadyReportsMissingLookupWithoutPoisoningValidReceipt(t *testing.T) {
	tracker := newCacheRoutingTracker(time.Minute, 2)
	cap := testV2Capability("11111111-1111-1111-1111-111111111111")
	prompt := protocol.PrefixCacheAnchor{ChainHash: strings.Repeat("c", 64), TokenCount: int(cap.BlockSize)}
	testV2Attempt(tracker, "nonce", cap, prompt)
	d := tracker.applyReadyV2Decision("provider", nil, cap, testV2Ready("nonce", cap, prompt, 2), []byte("route"), time.Now())
	if d.Reason != CacheReceiptLookupNotSeen {
		t.Fatalf("decision=%+v", d)
	}
	if !tracker.applyLookupV2("provider", cap, testV2Lookup("nonce", cap, prompt, 1), time.Now()) || !tracker.applyReadyV2("provider", cap, testV2Ready("nonce", cap, prompt, 2), time.Now()) {
		t.Fatal("diagnostic rejection poisoned valid later evidence")
	}
}

func TestCachePromptMismatchDiagnosticsPreserveExactRejection(t *testing.T) {
	for _, tc := range []struct {
		blocks int
		want   CachePromptMismatch
	}{{1, CachePromptShorter}, {2, CachePromptHashMismatch}, {3, CachePromptLonger}} {
		tracker := newCacheRoutingTracker(time.Minute, 2)
		cap := testV2Capability("11111111-1111-1111-1111-111111111111")
		prompt := protocol.PrefixCacheAnchor{ChainHash: strings.Repeat("c", 64), TokenCount: 2 * int(cap.BlockSize)}
		testV2Attempt(tracker, "nonce", cap, prompt)
		msg := testV2Lookup("nonce", cap, prompt, 1)
		msg.PromptAnchor.TokenCount = tc.blocks * int(cap.BlockSize)
		msg.PromptAnchor.ChainHash = strings.Repeat("f", 64)
		got := tracker.applyLookupV2Decision("provider", nil, cap, msg, []byte("route"), time.Now())
		if got.Accepted || !got.mismatch || got.Reason != CacheReceiptPromptMismatch || got.PromptMismatch != tc.want || got.PromptTokens != 0 {
			t.Fatalf("diagnostic=%+v", got)
		}
		if tracker.holderCount != 0 {
			t.Fatal("mismatch created a holder")
		}
	}
}
