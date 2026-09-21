package modelpolicy

import (
	"math"
	"testing"
	"time"
)

func TestBonsaiFirstContentSLA(t *testing.T) {
	for _, model := range []string{"ternary-bonsai-2-27b", "EigenLabs/Ternary-Bonsai-2-27B-MLX-2bit", "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit"} {
		if got := UpstreamFirstContentDeadline(model, 10_000, 10*time.Second); got != 60*time.Second {
			t.Fatalf("%s upstream=%s", model, got)
		}
		if got := CoordinatorFirstContentDeadline(model, 10_000, 5*time.Second); got != 59*time.Second {
			t.Fatalf("%s coordinator=%s", model, got)
		}
	}
	if got := UpstreamFirstContentDeadline("unrelated/Bonsai", 10_000, 10*time.Second); got != 20*time.Second {
		t.Fatal(got)
	}
	if got := UpstreamFirstContentDeadline("ternary-bonsai-2-27b", math.MaxInt, 10*time.Second); got != time.Duration(math.MaxInt64) {
		t.Fatal("duration overflow", got)
	}
}

func TestCustomFirstContentSLAValidationIsAtomic(t *testing.T) {
	basesMu.Lock()
	saved := exactBases
	exactBases = defaultExactFirstContentDeadlineBases()
	basesMu.Unlock()
	t.Cleanup(func() { basesMu.Lock(); exactBases = saved; basesMu.Unlock() })
	if err := SetFirstContentSLAsFromEnv("new/model=10000:3"); err != nil {
		t.Fatal(err)
	}
	if got := UpstreamFirstContentDeadline("new/model", 1000, time.Second); got != 13*time.Second {
		t.Fatal(got)
	}
	for _, bad := range []string{"new/model=10000:4,other=oops", "new/model=1000:3", "new/model=10000:-1", "new/model=10000:101", "new/model=10000:2,new/model=10000:4"} {
		if err := SetFirstContentSLAsFromEnv(bad); err == nil {
			t.Fatalf("accepted %q", bad)
		}
		if got := UpstreamFirstContentDeadline("new/model", 1000, 10*time.Second); got != 13*time.Second {
			t.Fatal("partial invalid update", got)
		}
	}
	if err := SetFirstContentSLAsFromEnv("new/model=off"); err != nil {
		t.Fatal(err)
	}
	if got := UpstreamFirstContentDeadline("new/model", 1000, 10*time.Second); got != 11*time.Second {
		t.Fatal(got)
	}
}
