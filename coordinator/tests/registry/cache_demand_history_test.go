package registry_test

import (
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
)

type demandFixture struct {
	tracker *cachedemand.Tracker
	index   *cachehistory.Index
}

func newDemandFixture(limit int, ttl time.Duration) *demandFixture {
	index := cachehistory.New()
	return &demandFixture{tracker: cachedemand.New(limit, ttl, index), index: index}
}

func TestCacheDemandIsBoundedSlidingAndDoesNotMatchItself(t *testing.T) {
	now := time.Unix(1000, 0)
	d := newDemandFixture(2, time.Minute)
	values := []cachedemand.Boundary{{Key: "short", Tokens: 256}, {Key: "long", Tokens: 1024}}
	if n, key := d.tracker.Observe(values, now); n != 0 || key != "" {
		t.Fatalf("first observation matched itself: %d %q", n, key)
	}
	if n, key := d.tracker.Observe(values, now.Add(30*time.Second)); n != 1024 || key != "long" {
		t.Fatalf("repeat=%d %q", n, key)
	}
	if n, _ := d.tracker.Observe(values, now.Add(80*time.Second)); n != 1024 {
		t.Fatal("live sliding history expired")
	}
	if n, _ := d.tracker.Observe(values, now.Add(141*time.Second)); n != 0 {
		t.Fatal("expired demand survived")
	}
	d.tracker.Observe([]cachedemand.Boundary{{Key: "third", Tokens: 2048}}, now.Add(142*time.Second))
	if d.index.Len() != 2 || len(d.index.Snapshot()) != 2 {
		t.Fatal("unbounded demand metadata")
	}
	if _, ok := d.index.Load("short"); ok {
		t.Fatal("oldest entry not evicted")
	}
}

func TestCacheDemandConcurrentCapacity(t *testing.T) {
	d := newDemandFixture(64, time.Minute)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				d.tracker.Observe([]cachedemand.Boundary{{Key: strconv.Itoa(i) + "/" + strconv.Itoa(j), Tokens: 256}}, time.Now())
			}
		}(i)
	}
	wg.Wait()
	if d.index.Len() > 64 || len(d.index.Snapshot()) != d.index.Len() {
		t.Fatal("concurrent capacity/order drift")
	}
}

func TestCacheDemandOutOfOrderTimestampsCannotReviveExpiredPrefixes(t *testing.T) {
	d := newDemandFixture(4, time.Minute)
	now := time.Unix(1000, 0)
	d.tracker.Observe([]cachedemand.Boundary{{Key: "newer", Tokens: 256}}, now)
	d.tracker.Observe([]cachedemand.Boundary{{Key: "older", Tokens: 512}}, now.Add(-10*time.Second))
	if repeated, _ := d.tracker.Observe([]cachedemand.Boundary{{Key: "older", Tokens: 512}}, now.Add(51*time.Second)); repeated != 0 {
		t.Fatal("expired entry hidden behind a newer entry was treated as repeat demand")
	}
}

// A boundary planned one minute short of the default TTL must still be found
// while other plans arrive at fleet rate. Before the dedicated cap the demand
// index shared the then 10,000-entry holder cap and turned over in about a
// minute, far inside the TTL, so nearly every real repeat looked novel.
func TestCacheDemandRetainsBoundaryForTTLAtFleetRate(t *testing.T) {
	const fillRatePerSecond, fillMinutes = 200, int(cachedemand.DefaultTTL/time.Minute) - 1
	const formerSharedCap = 10_000
	fill := func(d *demandFixture, start time.Time) time.Time {
		step := time.Second / fillRatePerSecond
		now := start
		for i := 0; i < fillRatePerSecond*60*fillMinutes; i++ {
			now = now.Add(step)
			d.tracker.Observe([]cachedemand.Boundary{{Key: "other/" + strconv.Itoa(i), Tokens: 256}}, now)
		}
		return now
	}
	start := time.Unix(1_700_000_000, 0)
	target := []cachedemand.Boundary{{Key: "repeated", Tokens: 1024}}

	sized := newDemandFixture(cachedemand.MaxEntries, cachedemand.DefaultTTL)
	sized.tracker.Observe(target, start)
	now := fill(sized, start)
	if got, key := sized.tracker.Observe(target, now); got != 1024 || key != "repeated" {
		t.Fatalf("boundary observed %s earlier at %d/s was lost: repeat=%d key=%q",
			now.Sub(start), fillRatePerSecond, got, key)
	}
	if len(sized.index.Snapshot()) != sized.index.Len() {
		t.Fatalf("map/order drift: %d vs %d", sized.index.Len(), len(sized.index.Snapshot()))
	}

	holderSized := newDemandFixture(formerSharedCap, cachedemand.DefaultTTL)
	holderSized.tracker.Observe(target, start)
	now = fill(holderSized, start)
	if got, _ := holderSized.tracker.Observe(target, now); got != 0 {
		t.Fatalf("holder-sized index unexpectedly retained the boundary: %d", got)
	}
}

// The demand index shares the routing TTL, which the operator is raising
// toward the 30 minutes providers keep cache files. 60 plans/s record 424
// entries/s on the 1,024-token stride. A boundary planned 29 minutes ago must
// still read as repeated at 450 entries/s; the former 600,000-entry cap
// turned over in under 23 minutes and reported it novel, which tells the
// provider not to write it.
func TestCacheDemandRetainsBoundaryFor29MinutesAtSizingRate(t *testing.T) {
	const fillRatePerSecond, fillMinutes = 450, 29
	const formerCap = 600_000
	target := []cachedemand.Boundary{{Key: "repeated", Tokens: 1024}}
	start := time.Unix(1_700_000_000, 0)
	for _, tc := range []struct {
		name     string
		limit    int
		retained bool
	}{
		{"sized", cachedemand.MaxEntries, true},
		{"former_cap", formerCap, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := newDemandFixture(tc.limit, cachedemand.SizingTTL)
			d.tracker.Observe(target, start)
			now := start
			for i := 0; i < fillRatePerSecond*60*fillMinutes; i++ {
				now = now.Add(time.Second / fillRatePerSecond)
				d.tracker.Observe([]cachedemand.Boundary{{Key: "other/" + strconv.Itoa(i), Tokens: 256}}, now)
			}
			if age := now.Sub(start); age < 28*time.Minute+59*time.Second || age >= cachedemand.SizingTTL {
				t.Fatalf("fill covered %s, want just under %d minutes", age, fillMinutes)
			}
			got, key := d.tracker.Observe(target, now)
			if retained := got == 1024 && key == "repeated"; retained != tc.retained {
				t.Fatalf("boundary observed %s earlier at %d/s: repeat=%d key=%q, retained want %v",
					now.Sub(start), fillRatePerSecond, got, key, tc.retained)
			}
			if d.index.Len() > tc.limit || len(d.index.Snapshot()) != d.index.Len() {
				t.Fatalf("entries=%d order=%d limit=%d", d.index.Len(), len(d.index.Snapshot()), tc.limit)
			}
		})
	}
}

func TestCacheDemandEvictsAtExactlyTheCap(t *testing.T) {
	d := newDemandFixture(cachedemand.MaxEntries, cachedemand.DefaultTTL)
	now := time.Unix(1_700_000_000, 0)
	for i := 0; i <= cachedemand.MaxEntries; i++ {
		d.tracker.Observe([]cachedemand.Boundary{{Key: "k/" + strconv.Itoa(i), Tokens: 256}}, now.Add(time.Duration(i)*time.Microsecond))
	}
	if d.index.Len() != cachedemand.MaxEntries || len(d.index.Snapshot()) != cachedemand.MaxEntries {
		t.Fatalf("entries=%d order=%d, want exactly %d", d.index.Len(), len(d.index.Snapshot()), cachedemand.MaxEntries)
	}
	if _, ok := d.index.Load("k/0"); ok {
		t.Fatal("oldest entry survived the cap")
	}
	if _, ok := d.index.Load("k/1"); !ok {
		t.Fatal("cap evicted more than one entry")
	}
	if _, ok := d.index.Load("k/" + strconv.Itoa(cachedemand.MaxEntries)); !ok {
		t.Fatal("newest entry missing")
	}
}

// The plan-path sweep must not drain a whole stale index under the lock. Each
// observe expires a bounded slice from the head; stale entries that remain are
// still never matched, and later calls finish draining.
func TestCacheDemandExpiryIsBoundedPerObserveAndStaleNeverMatches(t *testing.T) {
	const filled = 5 * cachedemand.MaxExpiryPerObserve
	d := newDemandFixture(cachedemand.MaxEntries, cachedemand.DefaultTTL)
	start := time.Unix(1_700_000_000, 0)
	for i := 0; i < filled; i++ {
		d.tracker.Observe([]cachedemand.Boundary{{Key: "stale/" + strconv.Itoa(i), Tokens: 512}}, start.Add(time.Duration(i)*time.Millisecond))
	}
	later := start.Add(cachedemand.DefaultTTL + time.Minute)
	if got, _ := d.tracker.Observe([]cachedemand.Boundary{{Key: "fresh", Tokens: 256}}, later); got != 0 {
		t.Fatalf("fresh key matched: %d", got)
	}
	if want := filled - cachedemand.MaxExpiryPerObserve + 1; d.index.Len() != want {
		t.Fatalf("one observe expired %d entries, want exactly %d (bounded)",
			filled+1-d.index.Len(), cachedemand.MaxExpiryPerObserve)
	}
	// A stale entry that survived the bounded sweep must not read as demand.
	if got, key := d.tracker.Observe([]cachedemand.Boundary{{Key: "stale/" + strconv.Itoa(filled-1), Tokens: 512}}, later); got != 0 || key != "" {
		t.Fatalf("stale surviving entry matched: %d %q", got, key)
	}
	for i := 0; i < filled/cachedemand.MaxExpiryPerObserve+1; i++ {
		d.tracker.Observe([]cachedemand.Boundary{{Key: "fresh/" + strconv.Itoa(i), Tokens: 256}}, later.Add(time.Duration(i)*time.Millisecond))
	}
	for _, entry := range d.index.Snapshot() {
		key := entry.Key
		if len(key) >= 6 && key[:6] == "stale/" && key != "stale/"+strconv.Itoa(filled-1) {
			t.Fatalf("stale entry %q survived repeated sweeps", key)
		}
	}
	if len(d.index.Snapshot()) != d.index.Len() {
		t.Fatal("map/order drift after bounded sweeps")
	}
}
