package registration

import (
	"strings"
)

func IsModelRegistryNotFound(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(strings.ToLower(err.Error()), "not found")
}
