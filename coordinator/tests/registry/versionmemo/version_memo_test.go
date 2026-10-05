package versionmemo_test

import (
	"fmt"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/versionmemo"
)

const (
	versionMemoCap        = 256
	maxMemoizedVersionLen = 64
)

var versionMemoCorpus = []string{
	"", " ", "v", "V", "0", "0.6", "0.6.0", "0.6.3", "0.6.10", "v0.6.3", "V0.6.3",
	" 0.7.5 ", "0.7.5", "0.7.4", "0.7.5-rc1", "0.7.5+build.7", "0.8.15", "v0.8.15-beta",
	"garbage", "1..2", "1.-2.3", "1.2.3.4.5", "a.b.c", "0.6.3-rc1", "00.06.03", "\u0663.\u0663",
}

// The memoized front must match the uncached parser on first and repeated use
// for every shape of input the fleet (or an attacker) can send.
func TestVersionSegmentsMemoMatchesParser(t *testing.T) {
	var memo versionmemo.Memo[[]int]
	for round := 0; round < 3; round++ {
		for _, v := range versionMemoCorpus {
			if got, want := versionmemo.Segments(&memo, v), versionmemo.ParseSegments(v); !slices.Equal(got, want) || (got == nil) != (want == nil) {
				t.Fatalf("round %d versionSegments(%q) = %v, want %v", round, v, got, want)
			}
			if _, hit := memo.Get(v); !hit {
				t.Fatalf("raw version %q was not memoized, including nil parses", v)
			}
		}
		for _, a := range versionMemoCorpus {
			for _, b := range versionMemoCorpus {
				want := compareParsedVersions(versionmemo.ParseSegments(a), versionmemo.ParseSegments(b))
				if got := versionmemo.Compare(&memo, a, b); got != want {
					t.Fatalf("round %d CompareVersions(%q,%q) = %d, want %d", round, a, b, got, want)
				}
			}
		}
	}
	// Spot-check the documented tolerances so the reference is not vacuous.
	if versionmemo.Compare(&memo, "0.6.10", "0.6.3") <= 0 || versionmemo.Compare(&memo, "0.6", "0.6.0") != 0 ||
		versionmemo.Compare(&memo, "garbage", "0") != 0 || versionmemo.Compare(&memo, "0.6.3-rc1", "0.6.0") != 0 {
		t.Fatal("documented CompareVersions tolerances no longer hold")
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

// A full memo retains all hot entries and computes later versions correctly.
// Hit/miss observations and allocations detect eviction, growth and rebuilding
// without exposing the copy-on-write map.
func TestVersionMemoFullCachePreservesHotEntries(t *testing.T) {
	var memo versionmemo.Memo[int]
	compute := func(key string) int { return len(key) }
	keys := []string{"0.8.15"}
	for i := 1; i < versionMemoCap; i++ {
		keys = append(keys, fmt.Sprintf("9.%d.0", i))
	}
	for _, key := range keys {
		memo.Load(key, compute, nil)
	}
	for i := 0; i < 3*versionMemoCap; i++ {
		key := fmt.Sprintf("10.%d.0", i)
		if got := memo.Load(key, compute, nil); got != len(key) {
			t.Fatalf("uncached version %q = %d, want %d", key, got, len(key))
		}
		if _, hit := memo.Get(key); hit {
			t.Fatal("a full memo discarded or rebuilt its cached entries")
		}
		for _, hot := range keys {
			if got, hit := memo.Get(hot); !hit || got != len(hot) {
				t.Fatal("a full memo discarded or rebuilt its cached entries")
			}
		}
	}
	if allocs := testing.AllocsPerRun(200, func() { memo.Load("uncached", compute, nil) }); allocs != 0 {
		t.Fatalf("full-cache misses allocated %v per run; want 0 beyond the parser", allocs)
	}
}

// Oversized keys and too many segments still parse correctly but consume no
// cache capacity. Both inclusive retention boundaries remain usable.
func TestVersionMemoNeverRetainsOversizedVersions(t *testing.T) {
	var memo versionmemo.Memo[[]int]
	_ = versionmemo.Segments(&memo, "0.8.15")
	meta := strings.Repeat("a", 1<<20)
	for i := 0; i < 8; i++ {
		huge := fmt.Sprintf("1.%d.0+%s%d", i, meta, i)
		if got := versionmemo.Segments(&memo, huge); !slices.Equal(got, []int{1, i, 0}) {
			t.Fatalf("oversized version parsed as %v", got)
		}
		if versionmemo.Compare(&memo, huge, "0.7.5") <= 0 {
			t.Fatal("oversized version must still compare correctly")
		}
	}
	for i := 0; i < 8; i++ {
		huge := fmt.Sprintf("1.%d.0+%s%d", i, meta, i)
		if _, hit := memo.Get(huge); hit {
			t.Fatal("a 1 MiB version string was retained in the memo")
		}
	}
	many := "1.2.3.4.5.6.7.8.9.10.11.12.13.14.15.16.17"
	if got := versionmemo.Segments(&memo, many); len(got) != 17 || got[16] != 17 {
		t.Fatalf("many-segment version parsed as %v", got)
	}
	if _, hit := memo.Get(many); hit {
		t.Fatal("over-segmented version was retained in the segments memo")
	}
	atBound := "1.0.0-" + strings.Repeat("x", maxMemoizedVersionLen-6)
	_ = versionmemo.Segments(&memo, atBound)
	if _, hit := memo.Get(atBound); !hit {
		t.Fatal("a key at the length bound must be memoized")
	}
	_ = versionmemo.Segments(&memo, atBound+"x")
	if _, hit := memo.Get(atBound + "x"); hit {
		t.Fatalf("segments memo holds a %d-byte key", len(atBound)+1)
	}
	atSegmentBound := strings.TrimSuffix(many, ".17")
	if got := versionmemo.Segments(&memo, atSegmentBound); len(got) != 16 || got[15] != 16 {
		t.Fatalf("segment-boundary version parsed as %v", got)
	}
	// Exactly four permitted keys have been loaded. Filling the remaining slots
	// detects hidden growth from oversized inputs, not just absence of their keys.
	keys := []string{"0.8.15", "0.7.5", atBound, atSegmentBound}
	for i := len(keys); i < versionMemoCap; i++ {
		key := fmt.Sprintf("9.%d.0", i)
		_ = versionmemo.Segments(&memo, key)
		keys = append(keys, key)
	}
	missing := 0
	for _, key := range keys {
		if _, hit := memo.Get(key); !hit {
			missing++
		}
	}
	if missing > 0 {
		// Every missing permitted key is a slot consumed beyond the one
		// permitted short comparison operand in the oversized-input phase.
		t.Fatalf("segments memo grew by %d entries on oversized keys, want at most 1 (the short operand)", 1+missing)
	}
	_ = versionmemo.Segments(&memo, "10.0.0")
	if _, hit := memo.Get("10.0.0"); hit {
		t.Fatal("segments memo grew beyond the entry bound")
	}
}

// A short version sliced out of a registration frame must not keep the frame's
// backing storage alive. Observe retained heap with the memo still live rather
// than exposing stored keys or relying on their representation.
func TestVersionMemoCopiesKeyStorage(t *testing.T) {
	var memo versionmemo.Memo[[]int]
	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)
	for i := 0; i < 32; i++ {
		short := fmt.Sprintf("1.%d.3", i)
		version := short + "+" + strings.Repeat("x", 1<<20)
		key := version[:len(short)]
		versionmemo.Segments(&memo, key)
	}
	runtime.GC()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	retained := int64(after.HeapAlloc) - int64(before.HeapAlloc)
	for i := 0; i < 32; i++ {
		key := fmt.Sprintf("1.%d.3", i)
		got, hit := memo.Get(key)
		if !hit {
			t.Fatalf("memo key = %q, want %q", "", key)
		}
		if !slices.Equal(got, []int{1, i, 3}) {
			t.Fatalf("short memo key %q lost its parsed value: %v, hit=%v", key, got, hit)
		}
	}
	runtime.KeepAlive(&memo)
	// Uncloned keys retain over 32 MiB; cloned keys retain only a few KiB.
	t.Logf("32 short keys retained %d heap bytes", retained)
	if retained >= 8<<20 {
		t.Fatal("short memo key retains the oversized version's backing storage")
	}
}

// Once a version has been seen, comparing it allocates nothing.
func TestVersionMemoReadsAllocateNothing(t *testing.T) {
	var memo versionmemo.Memo[[]int]
	const qwen4MinimumVersion = "0.9.6"
	_ = versionmemo.Compare(&memo, "0.9.9", qwen4MinimumVersion)
	_ = versionmemo.Compare(&memo, "0.9.9", "0.6.3")
	sink := 0
	allocs := testing.AllocsPerRun(200, func() {
		sink += versionmemo.Compare(&memo, "0.9.9", "0.6.3")
		sink += versionmemo.Compare(&memo, "0.9.9", qwen4MinimumVersion)
	})
	if allocs != 0 {
		t.Fatalf("warm version reads allocated %v per run; want 0", allocs)
	}
	if sink == 0 {
		t.Fatal("reads returned nothing")
	}
}

// Racing readers and inserters must observe correct parses under the race detector.
func TestVersionMemoConcurrentUse(t *testing.T) {
	var memo versionmemo.Memo[[]int]
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 500; i++ {
				v := fmt.Sprintf("1.%d.%d", (g*i)%40, i%5)
				if got, want := versionmemo.Segments(&memo, v), versionmemo.ParseSegments(v); !slices.Equal(got, want) || (got == nil) != (want == nil) {
					t.Errorf("versionSegments(%q) = %v, want %v", v, got, want)
					return
				}
				_ = versionmemo.Compare(&memo, v, "1.2.3")
			}
		}(g)
	}
	wg.Wait()
}
