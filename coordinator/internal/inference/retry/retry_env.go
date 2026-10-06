package retry

import (
	"os"
	"strings"
)

// envEnabledDefaultTrue parses a boolean env var that defaults to TRUE when
// unset. Only an explicit falsey value ("0"/"false"/"no"/"off",
// case-insensitive) disables the flag; anything else (including malformed input)
// leaves the default-safe behaviour enabled.
func EnvEnabledDefaultTrue(name string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(name))) {
	case "0", "false", "no", "off":
		return false
	default:
		return true
	}
}
