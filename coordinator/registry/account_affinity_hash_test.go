package registry

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func testAccountAffinityIdentity(identity string) accountAffinityIdentity {
	if value, ok := strings.CutPrefix(identity, "serial:"); ok {
		return accountAffinityIdentity{value: value, kind: accountAffinityIdentitySerial}
	}
	if value, ok := strings.CutPrefix(identity, "sekey:"); ok {
		return accountAffinityIdentity{value: value, kind: accountAffinityIdentitySEKey}
	}
	if identity == "" {
		return accountAffinityIdentity{}
	}
	panic("test identity must have an explicit physical namespace")
}

func TestAccountAffinityPhysicalIdentity(t *testing.T) {
	for _, tc := range []struct {
		name string
		p    *Provider
		want string
	}{
		{"nil", nil, ""},
		{"owner is not physical", &Provider{ID: "session", AccountID: "owner"}, ""},
		{"unverified", &Provider{AccountID: "owner", AttestationResult: &attestation.VerificationResult{SerialNumber: "serial", PublicKey: "key"}}, ""},
		{"serial preferred", &Provider{AttestationResult: &attestation.VerificationResult{Valid: true, SerialNumber: "serial", PublicKey: "key"}}, "serial:serial"},
		{"key fallback", &Provider{AttestationResult: &attestation.VerificationResult{Valid: true, PublicKey: "key"}}, "sekey:key"},
		{"no physical evidence", &Provider{AccountID: "owner", AttestationResult: &attestation.VerificationResult{Valid: true}}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := stableAccountAffinityIdentityLocked(tc.p); got != testAccountAffinityIdentity(tc.want) {
				t.Fatalf("got %+v, want %q", got, tc.want)
			}
		})
	}
	p := &Provider{ID: "old-session", AttestationResult: &attestation.VerificationResult{Valid: true, SerialNumber: "physical"}}
	before := accountAffinityScore("account", "model", stableAccountAffinityIdentityLocked(p))
	p.ID = "new-session"
	p.PublicKey = "rotated-transport-key"
	if after := accountAffinityScore("account", "model", stableAccountAffinityIdentityLocked(p)); before != after {
		t.Fatal("reconnect changed physical rank")
	}
}

func TestAccountAffinityHashFramingAndScope(t *testing.T) {
	seen := make(map[[32]byte]bool)
	for _, parts := range [][3]string{
		{"ab", "c", "serial:d"}, {"a", "bc", "serial:d"}, {"a", "b", "serial:cd"},
		{"account-a", "model-a", "serial:a"}, {"account-b", "model-a", "serial:a"},
		{"account-a", "model-b", "serial:a"}, {"account-a", "model-a", "sekey:a"},
	} {
		score := accountAffinityScore(parts[0], parts[1], testAccountAffinityIdentity(parts[2]))
		if seen[score] {
			t.Fatalf("ambiguous framing or scope: %q", parts)
		}
		seen[score] = true
		if accountAffinityScore(parts[0], parts[1], testAccountAffinityIdentity(parts[2])) != score {
			t.Fatal("hash not deterministic")
		}
	}
}

func TestAccountAffinityRankingMembershipChanges(t *testing.T) {
	pr := &PendingRequest{ConsumerKey: "account-a", Model: "model-a"}
	pool := make([]*routingCandidate, 0, 32)
	for i := 0; i < 32; i++ {
		candidate := newAccountAffinityPolicyCandidate(fmt.Sprintf("serial:%02d", i), 1000)
		candidate.accountAffinityScore = accountAffinityScore(pr.ConsumerKey, pr.Model, candidate.snapshot.affinityIdentity)
		pool = append(pool, candidate)
	}
	slices.SortFunc(pool, func(a, b *routingCandidate) int {
		if accountAffinityCandidateBefore(a, b) {
			return -1
		}
		return 1
	})
	// Removing arbitrary peers leaves the surviving order untouched. Joining
	// a machine inserts one new rank without reshuffling any existing pair.
	remaining := slices.Delete(slices.Clone(pool), 7, 17)
	newcomer := newAccountAffinityPolicyCandidate("serial:new", 1000)
	newcomer.accountAffinityScore = accountAffinityScore(pr.ConsumerKey, pr.Model, newcomer.snapshot.affinityIdentity)
	remaining = append(remaining, newcomer)
	for i, a := range pool {
		for _, b := range pool[i+1:] {
			if !accountAffinityCandidateBefore(a, b) {
				t.Fatal("existing pair reordered")
			}
		}
	}
	cfg := AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250}
	winner, _ := evaluateAccountAffinity(remaining, pr, cfg)
	want := pool[0]
	if accountAffinityCandidateBefore(newcomer, want) {
		want = newcomer
	}
	if winner != want {
		t.Fatal("join/removal moved affinity to an unrelated existing provider")
	}
	// Account and concrete-model scopes actually distribute top choices, not
	// merely produce different scores with an accidentally fixed order.
	for _, varyModel := range []bool{false, true} {
		winners := make(map[accountAffinityIdentity]bool)
		for i := 0; i < 64; i++ {
			request := PendingRequest{ConsumerKey: pr.ConsumerKey, Model: pr.Model}
			if varyModel {
				request.Model = fmt.Sprintf("model-%d", i)
			} else {
				request.ConsumerKey = fmt.Sprintf("account-%d", i)
			}
			chosen, _ := evaluateAccountAffinity(pool, &request, cfg)
			winners[chosen.snapshot.affinityIdentity] = true
		}
		if len(winners) < 2 {
			t.Fatalf("varyModel=%v: no scope isolation", varyModel)
		}
	}
}

func TestAccountAffinityIdentityRepresentationPreservesHashesAndTies(t *testing.T) {
	identities := []string{"sekey:a", "sekey:serial:a", "serial:a", "serial:aa", "serial:sekey:a", "serial:机器\x00"}
	for _, identity := range identities {
		// Reproduce the original string representation's length-framed byte
		// stream independently. No account/model/machine should be re-ranked.
		h := sha256.New()
		_, _ = h.Write([]byte("darkbloom/account-affinity/v1\x00"))
		for _, part := range []string{"account\x00:机器", "concrete-model", identity} {
			var length [8]byte
			binary.BigEndian.PutUint64(length[:], uint64(len(part)))
			_, _ = h.Write(length[:])
			_, _ = h.Write([]byte(part))
		}
		var want [sha256.Size]byte
		h.Sum(want[:0])
		if got := accountAffinityScore("account\x00:机器", "concrete-model", testAccountAffinityIdentity(identity)); got != want {
			t.Fatalf("identity representation changed the hash for %q", identity)
		}
		for _, other := range identities {
			a, b := newAccountAffinityPolicyCandidate(identity, 1000), newAccountAffinityPolicyCandidate(other, 1000)
			// Both digests are zero here, forcing the physical-identity tie.
			if accountAffinityCandidateBefore(a, b) != (identity < other) {
				t.Fatalf("identity representation changed tie order for %q / %q", identity, other)
			}
			dp := DispatchPlan{affinity: accountAffinityPlanFence{enabled: true}}
			a.accountAffinityRanked, b.accountAffinityRanked = true, true
			if dp.entryBefore(planEntryFromCandidate(a), planEntryFromCandidate(b), false) != (identity < other) {
				t.Fatalf("plan identity tie order changed for %q / %q", identity, other)
			}
		}
	}
}
