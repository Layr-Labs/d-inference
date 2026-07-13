package registry

import (
	"testing"
)

// PendingSessionKeys returns exactly the non-nil session keys of pending
// requests, skipping nil entries, and the snapshot survives the pending map
// being cleared (the whole point: it is collected BEFORE Disconnect wipes it).
func TestPendingSessionKeys(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("prov-pending-keys", nil, testRegisterMessage())

	keyA := &[32]byte{1}
	keyB := &[32]byte{2}
	p.AddPending(&PendingRequest{RequestID: "req-a", SessionPrivKey: keyA})
	p.AddPending(&PendingRequest{RequestID: "req-b", SessionPrivKey: keyB})
	p.AddPending(&PendingRequest{RequestID: "req-nil-key"}) // no session key: skipped

	keys := p.PendingSessionKeys()
	if len(keys) != 2 {
		t.Fatalf("PendingSessionKeys returned %d keys, want 2", len(keys))
	}
	seen := map[*[32]byte]bool{}
	for _, k := range keys {
		seen[k] = true
	}
	if !seen[keyA] || !seen[keyB] {
		t.Fatalf("PendingSessionKeys missing expected pointers: got %v", keys)
	}

	// Snapshot semantics: wiping the pending map (as Disconnect does) must not
	// invalidate the already-collected slice.
	reg.Disconnect("prov-pending-keys")
	if len(keys) != 2 || !seen[keyA] || !seen[keyB] {
		t.Fatal("collected snapshot must remain valid after Disconnect")
	}
	if got := p.PendingSessionKeys(); len(got) != 0 {
		t.Fatalf("after Disconnect, PendingSessionKeys = %d keys, want 0", len(got))
	}
}

func TestPendingSessionKeysEmpty(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("prov-no-pending", nil, testRegisterMessage())
	if got := p.PendingSessionKeys(); len(got) != 0 {
		t.Fatalf("PendingSessionKeys on empty provider = %d keys, want 0", len(got))
	}
}
