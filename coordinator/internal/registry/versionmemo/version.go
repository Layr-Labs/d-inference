package versionmemo

import (
	"strconv"
	"strings"
)

// Compare compares dotted numeric versions, treating missing, unparseable and
// negative segments as zero. A leading v or V is ignored. Prerelease and build
// suffixes are not interpreted: "0.6.3-rc1" compares equal to "0.6.0".
func Compare(memo *Memo[[]int], a, b string) int {
	as := Segments(memo, a)
	bs := Segments(memo, b)
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
		switch {
		case av < bv:
			return -1
		case av > bv:
			return 1
		}
	}
	return 0
}

// Segments parses a version, memoizing by raw input. Results with more than 16
// segments are not retained. Returned slices are shared and must not be mutated.
func Segments(memo *Memo[[]int], v string) []int {
	return memo.Load(v, ParseSegments, memoizable)
}

func memoizable(segs []int) bool {
	return len(segs) <= maxSegments
}

// ParseSegments parses an uncached version. Empty input has no segments;
// unparseable and negative segments become zero.
func ParseSegments(v string) []int {
	v = strings.TrimSpace(v)
	if len(v) > 0 && (v[0] == 'v' || v[0] == 'V') {
		v = v[1:]
	}
	if v == "" {
		return nil
	}
	parts := strings.Split(v, ".")
	segs := make([]int, len(parts))
	for i, part := range parts {
		n, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil || n < 0 {
			n = 0
		}
		segs[i] = n
	}
	return segs
}
