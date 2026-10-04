package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"strings"
	"testing"
	"time"
)

func TestCacheLookupRejectionReasonsPreserveFences(t *testing.T) {
	for _, tc := range []struct {
		name     string
		reason   production.CacheReceiptReason
		mismatch bool
		change   func(*receiptKernelFixture, *protocol.PrefixCacheLookupV2Message)
	}{
		{"missing attempt", production.CacheReceiptAttemptUnavailable, false, func(t *receiptKernelFixture, m *protocol.PrefixCacheLookupV2Message) { m.CacheReceiptNonce = "unknown" }},
		{"wrong request", production.CacheReceiptAttemptBinding, false, func(t *receiptKernelFixture, m *protocol.PrefixCacheLookupV2Message) { m.RequestID = "other" }},
		{"identity", production.CacheReceiptIdentityMismatch, true, func(t *receiptKernelFixture, m *protocol.PrefixCacheLookupV2Message) {
			m.ModelAggregateHash = strings.Repeat("f", 64)
		}},
		{"prompt", production.CacheReceiptPromptMismatch, true, func(t *receiptKernelFixture, m *protocol.PrefixCacheLookupV2Message) {
			m.PromptAnchor.ChainHash = strings.Repeat("f", 64)
		}},
		{"sequence", production.CacheReceiptSequence, false, func(t *receiptKernelFixture, m *protocol.PrefixCacheLookupV2Message) { m.CacheSeq = 0 }},
		{"invalid shape", production.CacheReceiptInvalid, false, func(t *receiptKernelFixture, m *protocol.PrefixCacheLookupV2Message) { m.StageMs = -1 }},
		{"duplicate lookup", production.CacheReceiptDuplicateLookup, false, func(t *receiptKernelFixture, m *protocol.PrefixCacheLookupV2Message) {
			a := t.config.Attempts.Lookup(m.CacheReceiptNonce)
			a.LookupSeen = true
			t.config.Attempts.Store(m.CacheReceiptNonce, a)
		}},
		{"capability change", production.CacheReceiptCapabilityChanged, false, func(t *receiptKernelFixture, m *protocol.PrefixCacheLookupV2Message) {
			a := t.config.Attempts.Lookup(m.CacheReceiptNonce)
			a.V2Capability.Ready = false
			t.config.Attempts.Store(m.CacheReceiptNonce, a)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tracker := newReceiptKernelFixture(time.Minute, 2)
			cap := testV2Capability("11111111-1111-1111-1111-111111111111")
			prompt := protocol.PrefixCacheAnchor{ChainHash: strings.Repeat("c", 64), TokenCount: int(cap.BlockSize)}
			receiptTestAttempt(tracker.Tracker, "nonce", cap, prompt)
			msg := fenceTestV2Lookup("nonce", cap, prompt, 1)
			tc.change(tracker, msg)
			d := tracker.lookup(cap, msg, []byte("route"), time.Now())
			if d.Accepted || d.Reason != tc.reason || cacheReceiptMismatch(d) != tc.mismatch {
				t.Fatalf("decision=%+v", d)
			}
			if tracker.config.Holders.Len() != 0 {
				t.Fatal("rejected receipt created a holder")
			}
		})
	}
}

func TestCacheReadyReportsMissingLookupWithoutPoisoningValidReceipt(t *testing.T) {
	tracker := newReceiptKernelFixture(time.Minute, 2)
	cap := testV2Capability("11111111-1111-1111-1111-111111111111")
	prompt := protocol.PrefixCacheAnchor{ChainHash: strings.Repeat("c", 64), TokenCount: int(cap.BlockSize)}
	receiptTestAttempt(tracker.Tracker, "nonce", cap, prompt)
	d := tracker.ready(cap, fenceTestV2Ready("nonce", cap, prompt, 2), []byte("route"), time.Now())
	if d.Reason != production.CacheReceiptLookupNotSeen {
		t.Fatalf("decision=%+v", d)
	}
	if !tracker.lookup(cap, fenceTestV2Lookup("nonce", cap, prompt, 1), []byte("test-cache-route-key"), time.Now()).Accepted || !tracker.ready(cap, fenceTestV2Ready("nonce", cap, prompt, 2), []byte("test-cache-route-key"), time.Now()).Accepted {
		t.Fatal("diagnostic rejection poisoned valid later evidence")
	}
}

func TestCachePromptMismatchDiagnosticsPreserveExactRejection(t *testing.T) {
	for _, tc := range []struct {
		blocks int
		want   production.CachePromptMismatch
	}{{1, production.CachePromptShorter}, {2, production.CachePromptHashMismatch}, {3, production.CachePromptLonger}} {
		tracker := newReceiptKernelFixture(time.Minute, 2)
		cap := testV2Capability("11111111-1111-1111-1111-111111111111")
		prompt := protocol.PrefixCacheAnchor{ChainHash: strings.Repeat("c", 64), TokenCount: 2 * int(cap.BlockSize)}
		receiptTestAttempt(tracker.Tracker, "nonce", cap, prompt)
		msg := fenceTestV2Lookup("nonce", cap, prompt, 1)
		msg.PromptAnchor.TokenCount = tc.blocks * int(cap.BlockSize)
		msg.PromptAnchor.ChainHash = strings.Repeat("f", 64)
		got := tracker.lookup(cap, msg, []byte("route"), time.Now())
		if got.Accepted || !cacheReceiptMismatch(got) || got.Reason != production.CacheReceiptPromptMismatch || got.PromptMismatch != tc.want || got.PromptTokens != 0 {
			t.Fatalf("diagnostic=%+v", got)
		}
		if tracker.config.Holders.Len() != 0 {
			t.Fatal("mismatch created a holder")
		}
	}
}
