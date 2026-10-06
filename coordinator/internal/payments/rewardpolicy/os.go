package rewardpolicy

import (
	"strconv"
	"strings"
)

// OSVersionEligible requires a complete numeric macOS version at or above 27.
// Missing or malformed app claims cannot authorize new BASE rewards.
func OSVersionEligible(version string) bool {
	parts := strings.Split(version, ".")
	if len(parts) > 3 {
		return false
	}
	var major uint64
	for i, part := range parts {
		if part == "" {
			return false
		}
		for _, c := range part {
			if c < '0' || c > '9' {
				return false
			}
		}
		n, err := strconv.ParseUint(part, 10, 64)
		if err != nil {
			return false
		}
		if i == 0 {
			major = n
		}
	}
	return major >= 27
}
