package firstcontent

import "math"

// coverageConfidence independently verifies the Python qualifier's minimum
// one-sided 95% Clopper-Pearson bound: P[X >= covered | p=target] <= .05.
// The caller has validated 0 < target < 1 and bounded the combined training /
// validation population to 10000, as calibration.py requires. This is the same
// log-space binomial test used for prompt-count evidence, without allocating
// a per-observation array. An edited empirical fraction alone cannot qualify.
func coverageConfidence(total, covered int, target float64) bool {
	logN, _ := math.Lgamma(float64(total + 1))
	maximum, sum := math.Inf(-1), 0.0
	for count := covered; count <= total; count++ {
		logCount, _ := math.Lgamma(float64(count + 1))
		logRemaining, _ := math.Lgamma(float64(total - count + 1))
		term := logN - logCount - logRemaining + float64(count)*math.Log(target) + float64(total-count)*math.Log1p(-target)
		if term > maximum {
			sum = sum*math.Exp(maximum-term) + 1
			maximum = term
		} else {
			sum += math.Exp(term - maximum)
		}
	}
	return math.Exp(maximum)*sum <= .05
}
