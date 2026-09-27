package registry

import (
	"testing"
	"time"
)

// TestReadOnlyPolicyGettersUseReadLock pins that the three gauge/stats
// getters are readable while another goroutine holds the read lock — i.e.
// they no longer take the write lock and cannot serialize behind readers.
func TestReadOnlyPolicyGettersUseReadLock(t *testing.T) {
	reg := New(testLogger())
	reg.mu.RLock()
	defer reg.mu.RUnlock()
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = reg.CodeAttestationConfigured()
		_ = reg.CodeAttestationEnforced()
		_ = reg.ReleasePolicyEnforced()
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("read-only getters blocked behind a held read lock (write lock?)")
	}
}
