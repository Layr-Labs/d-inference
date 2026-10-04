package capacityvalue

import (
	"math"
)

// FinitePositive excludes invalid measurements from capacity calculations.
func FinitePositive(value float64) bool {
	return value > 0 && !math.IsNaN(value) && !math.IsInf(value, 0)
}

// FiniteNonnegative admits an explicit zero reclaim or workload measurement.
func FiniteNonnegative(value float64) bool {
	return value >= 0 && !math.IsNaN(value) && !math.IsInf(value, 0)
}
