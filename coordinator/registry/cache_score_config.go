package registry

import (
	"math"
	"os"
	"strings"
)

// An absent or blank optional limit leaves scoring bounded by avoidable work.
// Explicit zero remains a real zero-credit limit; malformed values fail Check.
func optionalCacheScoreLimit(key string) *float64 {
	if strings.TrimSpace(os.Getenv(key)) == "" {
		return nil
	}
	value := envStrictFloat(key, math.NaN())
	return &value
}

func validCacheScoreLimit(value *float64, maximum float64) bool {
	return value == nil || (!math.IsNaN(*value) && !math.IsInf(*value, 0) && *value >= 0 && *value <= maximum)
}

func cloneCacheScoreLimit(value *float64) *float64 {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}
