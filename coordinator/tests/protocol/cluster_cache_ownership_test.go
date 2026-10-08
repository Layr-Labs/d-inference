package protocol_test

// Mirrored cluster cache ownership tests: the canonical encoding and
// namespace digest must stay byte-identical with the Swift mirror
// (ProviderCoreTests/KVCacheSSD/ClusterCacheOwnershipTests.swift).

import (
	"encoding/hex"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/protocol"
)

func clusterCacheFixtureIdentity(t *testing.T) production.ClusterCacheIdentity {
	t.Helper()
	identity, err := production.NewClusterCacheIdentity(
		strings.Repeat("1", 64), strings.Repeat("2", 64), "prompt-contract-v1",
		strings.Repeat("3", 64), strings.Repeat("4", 64), "bfloat16", "epoch-7")
	if err != nil {
		t.Fatal(err)
	}
	return identity
}

func TestClusterCacheIdentityCanonicalVector(t *testing.T) {
	identity := clusterCacheFixtureIdentity(t)
	canonical := identity.ClusterCacheIdentityCanonical()
	const expectedPrefix = "darkbloom/cluster-cache-identity/v1\x00"
	if !strings.HasPrefix(string(canonical), expectedPrefix) {
		t.Fatal("canonical domain prefix changed")
	}
	// Domain (36) + 4×64 fixed digests + 3×(4-byte length + label).
	const expectedBytes = 36 + 4*64 + 4 + len("prompt-contract-v1") + 4 + len("bfloat16") + 4 + len("epoch-7")
	if len(canonical) != expectedBytes {
		t.Fatalf("canonical byte count changed: got %d want %d", len(canonical), expectedBytes)
	}
	// Namespace digest pinned for the Swift mirror; update both sides together.
	const expectedNamespace = "d9a9f866e1ab9efb081317777815a95401fe310b1f9e87730d86133f0655a569"
	if identity.NamespaceSHA256() != expectedNamespace {
		t.Fatalf("namespace digest changed: got %s", identity.NamespaceSHA256())
	}
	t.Logf("namespace vector: %s", identity.NamespaceSHA256())
	t.Logf("canonical vector: %s", hex.EncodeToString(canonical))
}

func TestClusterCacheIdentityRefusesFuzzyFields(t *testing.T) {
	valid := func() []string {
		return []string{strings.Repeat("1", 64), strings.Repeat("2", 64), "pc",
			strings.Repeat("3", 64), strings.Repeat("4", 64), "bfloat16", "e"}
	}
	cases := [][]string{
		{"", "2", "pc", "3", "4", "bfloat16", "e"},
		{strings.Repeat("1", 63), strings.Repeat("2", 64), "pc", strings.Repeat("3", 64), strings.Repeat("4", 64), "bfloat16", "e"},
		{strings.Repeat("1", 64), strings.Repeat("G", 64), "pc", strings.Repeat("3", 64), strings.Repeat("4", 64), "bfloat16", "e"},
		{strings.Repeat("1", 64), strings.Repeat("2", 64), "has space", strings.Repeat("3", 64), strings.Repeat("4", 64), "bfloat16", "e"},
		{strings.Repeat("1", 64), strings.Repeat("2", 64), "pc", strings.Repeat("3", 64), strings.Repeat("4", 64), "float64", "e"},
		{strings.Repeat("1", 64), strings.Repeat("2", 64), "pc", strings.Repeat("3", 64), strings.Repeat("4", 64), "bfloat16", ""},
	}
	for i, c := range cases {
		values := valid()
		copy(values, c)
		if _, err := production.NewClusterCacheIdentity(values[0], values[1], values[2], values[3], values[4], values[5], values[6]); err == nil {
			t.Fatalf("fuzzy case %d constructed a cluster cache identity", i)
		}
	}
}

func TestClusterCacheWriterLeaseFencing(t *testing.T) {
	identity := clusterCacheFixtureIdentity(t)
	lease, err := production.NewClusterCacheWriterLease(identity.NamespaceSHA256(),
		"/Library/Caches/cluster", 4242, 0, 7)
	if err != nil {
		t.Fatal(err)
	}
	if err := lease.AdmitsWriter(4242, 0, 7); err != nil {
		t.Fatalf("exact owner refused: %v", err)
	}
	for _, attempt := range []struct {
		processID int32
		rank      int
		epoch     uint64
	}{{4242, 1, 7}, {4243, 0, 7}, {4242, 0, 8}, {4242, 0, 6}} {
		if err := lease.AdmitsWriter(attempt.processID, attempt.rank, attempt.epoch); err == nil {
			t.Fatalf("stale writer admitted: %+v", attempt)
		}
	}
	// Supersession needs a strictly newer epoch and a different owner.
	if _, err := lease.Superseded(4242, 0, 8); err == nil {
		t.Fatal("same owner superseded itself")
	}
	if _, err := lease.Superseded(4243, 0, 7); err == nil {
		t.Fatal("older epoch superseded the lease")
	}
	next, err := lease.Superseded(4243, 1, 8)
	if err != nil {
		t.Fatal(err)
	}
	if err := next.AdmitsWriter(4242, 0, 7); err == nil {
		t.Fatal("previous owner regained the namespace after supersession")
	}
	if err := next.AdmitsWriter(4243, 1, 8); err != nil {
		t.Fatalf("new owner refused: %v", err)
	}
}
