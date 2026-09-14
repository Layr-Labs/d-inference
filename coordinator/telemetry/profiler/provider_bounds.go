package profiler

import (
	"time"
)

// Contract ranges (CONTRACT-WIRE.md §1).
const (
	maxProfileUS       int64 = 3_600_000_000     // 1 h in µs
	maxProfileNS       int64 = 3_600_000_000_000 // 1 h in ns
	maxProfileCount    int   = 1_000_000_000
	maxProfileBytes    int64 = 1 << 48
	maxProfileWallSkew       = 24 * time.Hour
)

// profileBounds clamps wire numerics into contract range while recording
// whether any value had to be clamped. Every method returns a NEW pointer so
// the stored struct never aliases the wire struct; nil stays nil (absent).
type profileBounds struct{ violated bool }

func (b *profileBounds) i64(p *int64, limit int64) *int64 {
	if p == nil {
		return nil
	}
	v := *p
	switch {
	case v < 0:
		v, b.violated = 0, true
	case v > limit:
		v, b.violated = limit, true
	}
	return &v
}

func (b *profileBounds) us(p *int64) *int64 { return b.i64(p, maxProfileUS) }

func (b *profileBounds) ns(p *int64) *int64 { return b.i64(p, maxProfileNS) }

func (b *profileBounds) bytes(p *int64) *int64 { return b.i64(p, maxProfileBytes) }

func (b *profileBounds) count(p *int) *int {
	if p == nil {
		return nil
	}
	v := *p
	switch {
	case v < 0:
		v, b.violated = 0, true
	case v > maxProfileCount:
		v, b.violated = maxProfileCount, true
	}
	return &v
}

// cloneProfileValue preserves an absent scalar and gives each projection its
// own value. Range-checked numerics still go through profileBounds.
func cloneProfileValue[T bool | int | int64](p *T) *T {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}

// nonDecreasing reports whether the PRESENT values are in non-decreasing
// order; absent (nil) stamps are skipped, so a partial profile from an early
// terminal still validates.
func nonDecreasing[T ~int | ~int64](vals ...*T) bool {
	var last T
	have := false
	for _, p := range vals {
		if p == nil {
			continue
		}
		if have && *p < last {
			return false
		}
		last, have = *p, true
	}
	return true
}
