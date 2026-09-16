package throughput

import "testing"

func TestSoloMedianReturnsMedianAndCount(t *testing.T) {
	r := NewObservations()
	for _, v := range []float64{18, 10, 14, 12, 16} {
		r.RecordSolo("model-a", "m4", v)
	}
	tps, n := r.SoloMedian("model-a", "m4")
	if tps != 14 || n != 5 {
		t.Fatalf("SoloMedian = (%v, %d), want (14, 5)", tps, n)
	}
	// The load-inclusive store must be untouched by solo recording.
	if got := r.Median("model-a", "m4"); got != 0 {
		t.Fatalf("Median = %v, want 0 (RecordSolo must not feed the load-inclusive store)", got)
	}
}

func TestSoloMedianEmptyAndInvalidSamples(t *testing.T) {
	r := NewObservations()
	if tps, n := r.SoloMedian("missing", "m4"); tps != 0 || n != 0 {
		t.Fatalf("SoloMedian(empty) = (%v, %d), want (0, 0)", tps, n)
	}
	r.RecordSolo("model", "m4", 0)
	r.RecordSolo("model", "m4", -3)
	r.RecordSolo("", "m4", 50)
	if tps, n := r.SoloMedian("model", "m4"); tps != 0 || n != 0 {
		t.Fatalf("SoloMedian(after invalid samples) = (%v, %d), want (0, 0)", tps, n)
	}
}

func TestSoloMedianFIFOCap(t *testing.T) {
	r := NewObservations()
	for i := 0; i < 50; i++ {
		r.RecordSolo("model", "chip", 100)
	}
	for i := 0; i < 10; i++ {
		r.RecordSolo("model", "chip", 200)
	}
	// 40 × 100 + 10 × 200 after FIFO eviction → median 100, count capped at 50.
	tps, n := r.SoloMedian("model", "chip")
	if tps != 100 || n != 50 {
		t.Fatalf("SoloMedian = (%v, %d), want (100, 50) after FIFO eviction", tps, n)
	}
}

// TestSoloMedianAllChipsMinOfClassMedians pins the CONSERVATIVE cross-class
// transfer: SoloMedianAllChips returns the MINIMUM of the per-class medians
// (never the pooled median, which a fast, sample-heavy class can dominate), the
// TOTAL sample count, and the number of CLASSES behind that minimum. A slow
// class (m1, median 20) and a fast class (m4, median 30) → the min (20), so the
// rate can never exceed the slowest class's typical rate and can never over-cap
// a slow box.
func TestSoloMedianAllChipsMinOfClassMedians(t *testing.T) {
	r := NewObservations()
	r.RecordSolo("model", "m1", 20)
	r.RecordSolo("model", "m1", 20)
	r.RecordSolo("model", "m4", 30)
	r.RecordSolo("model", "m4", 30)
	r.RecordSolo("model", "m4", 30)
	r.RecordSolo("other-model", "m4", 999) // different model must not pollute
	tps, n, classes := r.SoloMedianAllChips("model")
	if tps != 20 || n != 5 || classes != 2 {
		t.Fatalf("SoloMedianAllChips = (%v, %d, %d), want (20, 5, 2) — min of class medians, total count, class count", tps, n, classes)
	}

	// A fast class with MANY samples must not drag the min up: the pooled median
	// would be 30, but the slow class's median (12) is what a slow box can do.
	r2 := NewObservations()
	for range 20 {
		r2.RecordSolo("m", "M4|Max", 30) // fast, sample-heavy
	}
	r2.RecordSolo("m", "M1", 12) // slow, one sample
	if tps, n, classes := r2.SoloMedianAllChips("m"); tps != 12 || n != 21 || classes != 2 {
		t.Fatalf("SoloMedianAllChips = (%v, %d, %d), want (12, 21, 2) — fast class must not dominate the min", tps, n, classes)
	}

	// The class count is what lets the resolver tell a genuine cross-class
	// minimum from a single class's median wearing that name.
	r3 := NewObservations()
	r3.RecordSolo("m", "M4|Max", 70)
	if tps, n, classes := r3.SoloMedianAllChips("m"); tps != 70 || n != 1 || classes != 1 {
		t.Fatalf("SoloMedianAllChips = (%v, %d, %d), want (70, 1, 1) — one class is not a cross-class minimum", tps, n, classes)
	}

	// No samples at all: no classes.
	if tps, n, classes := NewObservations().SoloMedianAllChips("m"); tps != 0 || n != 0 || classes != 0 {
		t.Fatalf("SoloMedianAllChips on an empty store = (%v, %d, %d), want (0, 0, 0)", tps, n, classes)
	}
}
