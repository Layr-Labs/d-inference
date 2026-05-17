package registry

import "testing"

func TestTPSRegistryRecordAndMedian(t *testing.T) {
	r := NewTPSRegistry()

	r.Record("model-a", "m4", 80)
	r.Record("model-a", "m4", 90)
	r.Record("model-a", "m4", 100)

	median := r.Median("model-a", "m4")
	if median != 90 {
		t.Fatalf("median = %f, want 90", median)
	}
}

func TestTPSRegistryEvenCount(t *testing.T) {
	r := NewTPSRegistry()

	r.Record("model-a", "m4", 80)
	r.Record("model-a", "m4", 100)

	// Even count: average of two middle values = (80+100)/2 = 90
	median := r.Median("model-a", "m4")
	if median != 90 {
		t.Fatalf("median = %f, want 90", median)
	}
}

func TestTPSRegistryEmptyReturnsZero(t *testing.T) {
	r := NewTPSRegistry()
	if got := r.Median("unknown", "unknown"); got != 0 {
		t.Fatalf("median = %f, want 0 for empty", got)
	}
}

func TestTPSRegistryMaxSamples(t *testing.T) {
	r := NewTPSRegistry()
	// Fill with 50 samples of value 100
	for i := 0; i < 50; i++ {
		r.Record("model", "chip", 100)
	}
	// Add 10 samples of value 200 (should evict oldest)
	for i := 0; i < 10; i++ {
		r.Record("model", "chip", 200)
	}
	// 40 samples of 100, 10 samples of 200. Median should be 100.
	median := r.Median("model", "chip")
	if median != 100 {
		t.Fatalf("median = %f, want 100", median)
	}
}

func TestTPSRegistryIgnoresZeroAndNegative(t *testing.T) {
	r := NewTPSRegistry()
	r.Record("model", "chip", 0)
	r.Record("model", "chip", -5)
	r.Record("", "chip", 50)

	if got := r.Median("model", "chip"); got != 0 {
		t.Fatalf("median = %f, want 0 (all recordings invalid)", got)
	}
}

func TestTPSRegistryDifferentKeys(t *testing.T) {
	r := NewTPSRegistry()
	r.Record("model-a", "m4", 80)
	r.Record("model-b", "m4", 120)
	r.Record("model-a", "m3", 50)

	if got := r.Median("model-a", "m4"); got != 80 {
		t.Fatalf("model-a/m4 median = %f, want 80", got)
	}
	if got := r.Median("model-b", "m4"); got != 120 {
		t.Fatalf("model-b/m4 median = %f, want 120", got)
	}
	if got := r.Median("model-a", "m3"); got != 50 {
		t.Fatalf("model-a/m3 median = %f, want 50", got)
	}
}
