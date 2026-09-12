package registry

import (
	"math/rand"
	"sort"
	"testing"
)

// referenceTPSStore is the pre-cache read-time implementation of the TPS
// aggregates (copy + sort on every read), kept here as the oracle the cached
// registry must match sample-for-sample, including FIFO eviction at
// maxSamples and the cross-class minimum/total/class-count aggregate.
type referenceTPSStore struct {
	max         int
	samples     map[tpsKey][]float64
	soloSamples map[tpsKey][]float64
}

func newReferenceTPSStore(max int) *referenceTPSStore {
	return &referenceTPSStore{
		max:         max,
		samples:     make(map[tpsKey][]float64),
		soloSamples: make(map[tpsKey][]float64),
	}
}

func referenceMedian(samples []float64) float64 {
	if len(samples) == 0 {
		return 0
	}
	sorted := append([]float64(nil), samples...)
	sort.Float64s(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 0 {
		return (sorted[mid-1] + sorted[mid]) / 2
	}
	return sorted[mid]
}

func (s *referenceTPSStore) record(m map[tpsKey][]float64, model, chip string, tps float64) {
	if tps <= 0 || model == "" {
		return
	}
	key := tpsKey{Model: model, ChipFamily: chip}
	samples := m[key]
	if len(samples) >= s.max {
		samples = samples[1:]
	}
	m[key] = append(samples, tps)
}

func (s *referenceTPSStore) median(model, chip string) float64 {
	return referenceMedian(s.samples[tpsKey{Model: model, ChipFamily: chip}])
}

func (s *referenceTPSStore) soloMedian(model, chip string) (float64, int) {
	samples := s.soloSamples[tpsKey{Model: model, ChipFamily: chip}]
	return referenceMedian(samples), len(samples)
}

func (s *referenceTPSStore) soloMedianAllChips(model string) (float64, int, int) {
	perClass := make(map[string][]float64)
	for key, samples := range s.soloSamples {
		if key.Model != model || len(samples) == 0 {
			continue
		}
		perClass[key.ChipFamily] = append(perClass[key.ChipFamily], samples...)
	}
	minMedian, total, classes := 0.0, 0, 0
	for _, samples := range perClass {
		m := referenceMedian(samples)
		total += len(samples)
		if m <= 0 {
			continue
		}
		if classes == 0 || m < minMedian {
			minMedian = m
		}
		classes++
	}
	return minMedian, total, classes
}

// TestTPSRegistryCachedAggregatesMatchReference drives random Record /
// RecordSolo sequences (well past the 50-sample ring) through the cached
// registry and the reference store and checks every aggregate after every
// write, so the write-time maintenance can never drift from the former
// read-time computation.
func TestTPSRegistryCachedAggregatesMatchReference(t *testing.T) {
	rng := rand.New(rand.NewSource(20260902))
	reg := NewTPSRegistry()
	ref := newReferenceTPSStore(reg.maxSamples)
	models := []string{"m-a", "m-b", "m-c"}
	chips := []string{"M1", "M2|Max", "M3|Pro", "M4|Max"}

	check := func(step int) {
		t.Helper()
		for _, model := range models {
			for _, chip := range chips {
				if got, want := reg.Median(model, chip), ref.median(model, chip); got != want {
					t.Fatalf("step %d Median(%s,%s)=%v want %v", step, model, chip, got, want)
				}
				gotM, gotN := reg.SoloMedian(model, chip)
				wantM, wantN := ref.soloMedian(model, chip)
				if gotM != wantM || gotN != wantN {
					t.Fatalf("step %d SoloMedian(%s,%s)=(%v,%d) want (%v,%d)", step, model, chip, gotM, gotN, wantM, wantN)
				}
			}
			gotT, gotS, gotC := reg.SoloMedianAllChips(model)
			wantT, wantS, wantC := ref.soloMedianAllChips(model)
			if gotT != wantT || gotS != wantS || gotC != wantC {
				t.Fatalf("step %d SoloMedianAllChips(%s)=(%v,%d,%d) want (%v,%d,%d)", step, model, gotT, gotS, gotC, wantT, wantS, wantC)
			}
		}
		// Unknown keys read as empty on both.
		if reg.Median("nope", "M1") != 0 {
			t.Fatalf("step %d unknown Median must be 0", step)
		}
		if m, n := reg.SoloMedian("nope", "M1"); m != 0 || n != 0 {
			t.Fatalf("step %d unknown SoloMedian must be (0,0)", step)
		}
		if m, s, c := reg.SoloMedianAllChips("nope"); m != 0 || s != 0 || c != 0 {
			t.Fatalf("step %d unknown SoloMedianAllChips must be zero", step)
		}
	}

	check(0)
	for step := 1; step <= 4000; step++ {
		model := models[rng.Intn(len(models))]
		chip := chips[rng.Intn(len(chips))]
		// Include rejected values (<= 0) and an empty model to pin the ingest guards.
		tps := float64(rng.Intn(120)) - 5
		if rng.Intn(50) == 0 {
			model = ""
		}
		if rng.Intn(2) == 0 {
			reg.Record(model, chip, tps)
			ref.record(ref.samples, model, chip, tps)
		} else {
			reg.RecordSolo(model, chip, tps)
			ref.record(ref.soloSamples, model, chip, tps)
		}
		check(step)
	}
	// The ring must actually have evicted: a key that received > maxSamples
	// writes holds exactly maxSamples.
	for key, samples := range reg.samples {
		if len(samples) > reg.maxSamples {
			t.Fatalf("ring for %+v grew past maxSamples: %d", key, len(samples))
		}
	}
}

// TestTPSRegistryZeroValueDoesNotPanic pins that a bare TPSRegistry{} (no
// NewTPSRegistry: maps nil, maxSamples 0 ⇒ unbounded ring) records and reads
// correctly, including a ring longer than the nominal 50-sample bound, which
// used to make the scratch allocation panic (len > cap).
func TestTPSRegistryZeroValueDoesNotPanic(t *testing.T) {
	var reg TPSRegistry
	ref := newReferenceTPSStore(1 << 30) // effectively unbounded, like maxSamples 0
	for i := 0; i < 130; i++ {
		v := float64(1 + i%23)
		reg.Record("m", "M3", v)
		ref.record(ref.samples, "m", "M3", v)
		reg.RecordSolo("m", "M3|Max", v)
		ref.record(ref.soloSamples, "m", "M3|Max", v)
	}
	if n := len(reg.samples[tpsKey{Model: "m", ChipFamily: "M3"}]); n != 130 {
		t.Fatalf("unbounded ring length = %d, want 130", n)
	}
	if got, want := reg.Median("m", "M3"), ref.median("m", "M3"); got != want {
		t.Fatalf("zero-value Median = %v, want %v", got, want)
	}
	gotM, gotN := reg.SoloMedian("m", "M3|Max")
	wantM, wantN := ref.soloMedian("m", "M3|Max")
	if gotM != wantM || gotN != wantN {
		t.Fatalf("zero-value SoloMedian = (%v,%d), want (%v,%d)", gotM, gotN, wantM, wantN)
	}
	gotT, gotS, gotC := reg.SoloMedianAllChips("m")
	wantT, wantS, wantC := ref.soloMedianAllChips("m")
	if gotT != wantT || gotS != wantS || gotC != wantC {
		t.Fatalf("zero-value SoloMedianAllChips = (%v,%d,%d), want (%v,%d,%d)", gotT, gotS, gotC, wantT, wantS, wantC)
	}
	var empty TPSRegistry
	if empty.Median("x", "y") != 0 {
		t.Fatal("empty zero-value registry must read 0")
	}
	if m, s, c := empty.SoloMedianAllChips("x"); m != 0 || s != 0 || c != 0 {
		t.Fatal("empty zero-value registry must read zero aggregates")
	}
}

// TestTPSRegistryReadsAllocateNothing pins the hot-path contract: every read
// aggregate is a map lookup with zero allocations.
func TestTPSRegistryReadsAllocateNothing(t *testing.T) {
	reg := NewTPSRegistry()
	for i := 0; i < 120; i++ {
		reg.Record("m", "M3", float64(10+i%37))
		reg.RecordSolo("m", "M3|Max", float64(10+i%29))
		reg.RecordSolo("m", "M4|Max", float64(20+i%31))
	}
	var sink float64
	var sinkN int
	allocs := testing.AllocsPerRun(200, func() {
		sink += reg.Median("m", "M3")
		m, n := reg.SoloMedian("m", "M3|Max")
		sink += m
		sinkN += n
		a, s, c := reg.SoloMedianAllChips("m")
		sink += a
		sinkN += s + c
	})
	if allocs != 0 {
		t.Fatalf("TPS reads allocated %v per run; want 0", allocs)
	}
	if sink == 0 || sinkN == 0 {
		t.Fatal("reads returned nothing; fixture broken")
	}
}

// TestTPSRegistryRingEvictionSemantics pins FIFO eviction: once full, the
// oldest sample leaves and the newest enters, so the median tracks the most
// recent maxSamples observations exactly as the former re-slice form did.
func TestTPSRegistryRingEvictionSemantics(t *testing.T) {
	reg := NewTPSRegistry()
	for i := 1; i <= reg.maxSamples; i++ {
		reg.Record("m", "M3", 10) // ring full of 10s
	}
	if got := reg.Median("m", "M3"); got != 10 {
		t.Fatalf("full ring median = %v, want 10", got)
	}
	// Push maxSamples values of 30: after exactly maxSamples writes every 10
	// has been evicted, and halfway the median is the mean of the middle pair.
	for i := 1; i <= reg.maxSamples; i++ {
		reg.Record("m", "M3", 30)
		if i == reg.maxSamples/2 {
			if got := reg.Median("m", "M3"); got != 20 {
				t.Fatalf("half-replaced ring median = %v, want 20", got)
			}
		}
	}
	if got := reg.Median("m", "M3"); got != 30 {
		t.Fatalf("fully replaced ring median = %v, want 30", got)
	}
	if n := len(reg.samples[tpsKey{Model: "m", ChipFamily: "M3"}]); n != reg.maxSamples {
		t.Fatalf("ring length = %d, want %d", n, reg.maxSamples)
	}
}
