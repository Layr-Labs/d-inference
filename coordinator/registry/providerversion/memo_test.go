package providerversion

import (
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
	"unsafe"
)

var versionMemoCorpus = []string{
	"", " ", "v", "V", "0", "0.6", "0.6.0", "0.6.3", "0.6.10", "v0.6.3", "V0.6.3",
	" 0.7.5 ", "0.7.5", "0.7.4", "0.7.5-rc1", "0.7.5+build.7", "0.8.15", "v0.8.15-beta",
	"garbage", "1..2", "1.-2.3", "1.2.3.4.5", "a.b.c", "0.6.3-rc1", "00.06.03", "٣.٣",
}

// TestVersionSegmentsMemoMatchesParser pins that the memoized front returns
// exactly what the uncached parser returns, on first and repeated use, for
// every shape of input the fleet (or an attacker) can send.
func TestVersionSegmentsMemoMatchesParser(t *testing.T) {
	var policy Policy
	policy.versionSegmentsMemo.reset()
	policy.slotBudgetLayoutMemo.reset()
	for round := 0; round < 3; round++ {
		for _, v := range versionMemoCorpus {
			if got, want := policy.versionSegments(v), parseVersionSegments(v); !reflect.DeepEqual(got, want) {
				t.Fatalf("round %d versionSegments(%q) = %v, want %v", round, v, got, want)
			}
			if got, want := policy.SlotBudgetLayout(v), policy.parseSlotBudgetLayout(v); got != want {
				t.Fatalf("round %d slotBudgetLayoutForVersion(%q) = %v, want %v", round, v, got, want)
			}
		}
		for _, a := range versionMemoCorpus {
			for _, b := range versionMemoCorpus {
				want := compareParsedVersions(parseVersionSegments(a), parseVersionSegments(b))
				if got := policy.Compare(a, b); got != want {
					t.Fatalf("round %d CompareVersions(%q,%q) = %d, want %d", round, a, b, got, want)
				}
			}
		}
	}
	// Spot-check the documented tolerances so the reference is not vacuous.
	if policy.Compare("0.6.10", "0.6.3") <= 0 || policy.Compare("0.6", "0.6.0") != 0 ||
		policy.Compare("garbage", "0") != 0 || policy.Compare("0.6.3-rc1", "0.6.0") != 0 {
		t.Fatal("documented CompareVersions tolerances no longer hold")
	}
	if policy.SlotBudgetLayout("0.7.5-rc1") != PrivateSlotGrants || policy.SlotBudgetLayout("0.7.4") != SharedSlotHeadroom {
		t.Fatal("layout floor no longer honored")
	}
}

func compareParsedVersions(as, bs []int) int {
	n := len(as)
	if len(bs) > n {
		n = len(bs)
	}
	for i := 0; i < n; i++ {
		var av, bv int
		if i < len(as) {
			av = as[i]
		}
		if i < len(bs) {
			bv = bs[i]
		}
		if av < bv {
			return -1
		}
		if av > bv {
			return 1
		}
	}
	return 0
}

// A full memo retains its hot entries and computes later versions correctly
// without rebuilding. The saved map identity and allocation check catch the
// old reset-and-regrow behavior even when every returned value is correct.
func TestVersionMemoFullCachePreservesHotEntries(t *testing.T) {
	var memo cowMemo[int]
	compute := func(key string) int { return len(key) }
	memo.get("0.8.15", compute)
	for i := 1; i < versionMemoCap; i++ {
		memo.get(fmt.Sprintf("9.%d.0", i), compute)
	}
	full := memo.entries.Load()
	for i := 0; i < 3*versionMemoCap; i++ {
		key := fmt.Sprintf("10.%d.0", i)
		if got := memo.get(key, compute); got != len(key) {
			t.Fatalf("uncached version %q = %d, want %d", key, got, len(key))
		}
		if memo.entries.Load() != full || memo.size() != versionMemoCap || !memo.has("0.8.15") {
			t.Fatal("a full memo discarded or rebuilt its cached entries")
		}
	}
	if allocs := testing.AllocsPerRun(200, func() { memo.get("uncached", compute) }); allocs != 0 {
		t.Fatalf("full-cache misses allocated %v per run; want 0 beyond the parser", allocs)
	}
}

// TestVersionMemoNeverRetainsOversizedVersions pins the byte bound: a 1 MiB
// version string (a valid "1.0.0+<metadata>" that fits the frame limit) is
// parsed correctly and selects the right layout, but leaves the segments memo
// unchanged and adds at most the shared numeric-core entry to the layout memo
// — so distinct oversized strings cannot grow either memo. A short string
// with too many segments is likewise parsed but not retained.
func TestVersionMemoNeverRetainsOversizedVersions(t *testing.T) {
	var policy Policy
	policy.versionSegmentsMemo.reset()
	policy.slotBudgetLayoutMemo.reset()
	_ = policy.versionSegments("0.8.15") // warm one real entry
	_ = policy.SlotBudgetLayout("0.8.15")
	segsBefore, layoutBefore := policy.versionSegmentsMemo.size(), policy.slotBudgetLayoutMemo.size()

	meta := strings.Repeat("a", 1<<20)
	for i := 0; i < 8; i++ {
		huge := fmt.Sprintf("1.%d.0+%s%d", i, meta, i) // distinct 1 MiB strings, distinct cores
		if got := policy.versionSegments(huge); !reflect.DeepEqual(got, []int{1, i, 0}) {
			t.Fatalf("oversized version parsed as %v", got)
		}
		if got := policy.SlotBudgetLayout(huge); got != PrivateSlotGrants {
			t.Fatalf("oversized version layout = %v, want privateSlotGrants", got)
		}
		if policy.Compare(huge, "0.7.5") <= 0 {
			t.Fatal("oversized version must still compare correctly")
		}
	}
	// Only the short numeric cores ("1.N.0", via the layout path's
	// CompareVersions) may have been retained — never a 1 MiB key.
	if grown := policy.versionSegmentsMemo.size() - segsBefore; grown > 8 {
		t.Fatalf("segments memo grew by %d entries on oversized keys", grown)
	}
	for i := 0; i < 8; i++ {
		huge := fmt.Sprintf("1.%d.0+%s%d", i, meta, i)
		if policy.versionSegmentsMemo.has(huge) || policy.slotBudgetLayoutMemo.has(huge) {
			t.Fatal("a 1 MiB version string was retained in a memo")
		}
	}
	if l := policy.versionSegmentsMemo.maxKeyLen(); l > maxMemoizedVersionLen {
		t.Fatalf("segments memo holds a %d-byte key", l)
	}
	if l := policy.slotBudgetLayoutMemo.maxKeyLen(); l > maxMemoizedVersionLen {
		t.Fatalf("layout memo holds a %d-byte key", l)
	}
	// The layout memo keys on the numeric core ("1.N.0"): 8 distinct cores at
	// most, never the 1 MiB strings themselves.
	if grown := policy.slotBudgetLayoutMemo.size() - layoutBefore; grown > 8 {
		t.Fatalf("layout memo grew by %d entries", grown)
	}
	// The same core with different oversized suffixes shares ONE layout entry.
	layoutMid := policy.slotBudgetLayoutMemo.size()
	for i := 0; i < 8; i++ {
		_ = policy.SlotBudgetLayout(fmt.Sprintf("2.0.0+%s%d", meta, i))
	}
	if policy.slotBudgetLayoutMemo.size() != layoutMid+1 {
		t.Fatalf("suffix variants of one core created %d layout entries, want 1", policy.slotBudgetLayoutMemo.size()-layoutMid)
	}
	// An oversized numeric core is computed without caching.
	longCore := strings.Repeat("1.", 60) + "1" // 121 bytes, all segments
	if got := policy.SlotBudgetLayout(longCore); got != PrivateSlotGrants {
		t.Fatalf("long-core layout = %v", got)
	}
	if policy.slotBudgetLayoutMemo.size() != layoutMid+1 {
		t.Fatal("oversized numeric core was retained in the layout memo")
	}
	// Too many segments in a short string: parsed, not retained.
	many := "1.2.3.4.5.6.7.8.9.10.11.12.13.14.15.16.17"
	if got := policy.versionSegments(many); len(got) != 17 || got[16] != 17 {
		t.Fatalf("many-segment version parsed as %v", got)
	}
	if policy.versionSegmentsMemo.has(many) {
		t.Fatal("over-segmented version was retained in the segments memo")
	}
	// A key exactly at the length bound is still memoized.
	atBound := "1.0.0-" + strings.Repeat("x", maxMemoizedVersionLen-6)
	_ = policy.versionSegments(atBound)
	if !policy.versionSegmentsMemo.has(atBound) {
		t.Fatal("a key at the length bound must be memoized")
	}
}

// A normalized core is a substring of the registration version. Retaining
// that substring's storage would defeat the byte bound even though len(key)
// is small; compare storage identity without dereferencing either pointer.
func TestVersionMemoCopiesNormalizedKeyStorage(t *testing.T) {
	var policy Policy
	var memo cowMemo[SlotBudgetLayout]
	version := "1.2.3+" + strings.Repeat("x", 1<<20)
	core := NumericCore(version)
	memo.get(core, policy.parseSlotBudgetLayoutCore)
	for key := range *memo.entries.Load() {
		if key != core {
			t.Fatalf("memo key = %q, want %q", key, core)
		}
		if unsafe.StringData(key) == unsafe.StringData(version) {
			t.Fatal("short memo key retains the oversized version's backing storage")
		}
	}
}

// TestVersionMemoReadsAllocateNothing pins the hot-path contract: once a
// version has been seen, comparing it and selecting its budget layout
// allocate nothing.
func TestVersionMemoReadsAllocateNothing(t *testing.T) {
	var policy Policy
	policy.versionSegmentsMemo.reset()
	policy.slotBudgetLayoutMemo.reset()
	_ = policy.Compare("0.8.15", privateSlotGrantsMinVersion)
	_ = policy.Compare("0.8.15", "0.6.3")
	_ = policy.SlotBudgetLayout("0.8.15")
	_ = policy.SlotBudgetLayout("v0.7.5-rc1")
	sink := 0
	allocs := testing.AllocsPerRun(200, func() {
		sink += policy.Compare("0.8.15", "0.6.3")
		sink += policy.Compare("0.8.15", privateSlotGrantsMinVersion)
		sink += int(policy.SlotBudgetLayout("0.8.15"))
		sink += int(policy.SlotBudgetLayout("v0.7.5-rc1"))
	})
	if allocs != 0 {
		t.Fatalf("warm version reads allocated %v per run; want 0", allocs)
	}
	if sink == 0 {
		t.Fatal("reads returned nothing")
	}
}

// TestVersionMemoConcurrentUse exercises racing readers and inserters
// (meaningful under -race): every goroutine must observe correct parses.
func TestVersionMemoConcurrentUse(t *testing.T) {
	var policy Policy
	policy.versionSegmentsMemo.reset()
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 500; i++ {
				v := fmt.Sprintf("1.%d.%d", (g*i)%40, i%5)
				if got, want := policy.versionSegments(v), parseVersionSegments(v); !reflect.DeepEqual(got, want) {
					t.Errorf("versionSegments(%q) = %v, want %v", v, got, want)
					return
				}
				_ = policy.Compare(v, "1.2.3")
				_ = policy.SlotBudgetLayout(v)
			}
		}(g)
	}
	wg.Wait()
}
