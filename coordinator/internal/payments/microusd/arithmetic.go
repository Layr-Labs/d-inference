package microusd

import (
	"math"
	"math/bits"
)

// termCost is tokens × ratePerMillion / 1_000_000 floored to whole micro-USD,
// 0 for a non-positive count or rate, saturating at math.MaxInt64 when the
// product does not fit in 64 bits.
func TermCost(tokens int, ratePerMillion int64) int64 {
	if tokens <= 0 || ratePerMillion <= 0 {
		return 0
	}
	hi, lo := bits.Mul64(uint64(tokens), uint64(ratePerMillion))
	if hi >= 1_000_000 {
		// The quotient itself would not fit in 64 bits.
		return math.MaxInt64
	}
	q, _ := bits.Div64(hi, lo, 1_000_000)
	if q > math.MaxInt64 {
		return math.MaxInt64
	}
	return int64(q)
}

// saturatingAdd adds two non-negative micro-USD amounts without wrapping.
func Add(a, b int64) int64 {
	if a > math.MaxInt64-b {
		return math.MaxInt64
	}
	return a + b
}
