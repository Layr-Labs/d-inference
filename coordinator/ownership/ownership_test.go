package ownership

import "testing"

func TestGate_RefuseUnsafeStartup(t *testing.T) {
	g := NewGate(true)
	g.SetRustActive(true)
	if err := g.CheckStartup(nil); err != ErrUnsafeStartup {
		t.Fatalf("err = %v, want ErrUnsafeStartup", err)
	}
	if err := g.Acquire(1); err != ErrUnsafeStartup {
		t.Fatalf("Acquire err = %v, want ErrUnsafeStartup", err)
	}

	g.EnableRecoveryMode()
	if err := g.CheckStartup(nil); err != nil {
		t.Fatalf("recovery mode should allow startup: %v", err)
	}
	if err := g.Acquire(2); err != nil {
		t.Fatal(err)
	}
	if !g.Holding() || g.Epoch() != 2 {
		t.Fatalf("holding=%v epoch=%d", g.Holding(), g.Epoch())
	}
	g.Release()
	if err := g.AssertHolding(); err != ErrOwnershipLost {
		t.Fatalf("err = %v", err)
	}
}

func TestGate_AllowsWhenNoRustActive(t *testing.T) {
	g := NewGate(true)
	g.SetRustActive(false)
	if err := g.Acquire(9); err != nil {
		t.Fatal(err)
	}
	if err := g.AssertHolding(); err != nil {
		t.Fatal(err)
	}
}
