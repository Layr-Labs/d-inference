package extract

import "testing"

func TestVerbMode(t *testing.T) {
	cases := map[string]string{
		"GetProvider":      ModeRead,
		"ListModels":       ModeRead,
		"StatusSnapshot":   ModeRead,
		"ResolveAlias":     ModeRead,
		"SetTrust":         ModeWrite,
		"UpdateBudget":     ModeWrite,
		"RecordUsage":      ModeWrite,
		"InvalidateCache":  ModeWrite,
		"Dequeue":          ModeBoth,
		"GetOrCreateUser":  ModeBoth,
		"CompareAndSwap":   ModeBoth,
		"Frobnicate":       ModeRead, // unknown verb: the call at least observes
		"CreateOrGetLease": ModeWrite,
	}
	for name, want := range cases {
		if got := verbMode(name); got != want {
			t.Errorf("verbMode(%q) = %q, want %q", name, got, want)
		}
	}
}
