package statearchive

import (
	"os"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// State-export env vars (all namespaced under env.EnvPrefix == "EIGENINFERENCE").
const (
	// envStateExportEnabled is the master switch. When != "true" the route 404s.
	envStateExportEnabled = env.EnvPrefix + "_STATE_EXPORT_ENABLED"
	// envStateExportRecipient is an age recipient ("age1..."). When set, output is
	// encrypted to it; this is the default-secure path.
	envStateExportRecipient = env.EnvPrefix + "_STATE_EXPORT_RECIPIENT"
	// envStateExportAllowPlaintext permits a raw (unencrypted) zip ONLY when no
	// recipient is configured. Must be explicitly "true".
	envStateExportAllowPlaintext = env.EnvPrefix + "_STATE_EXPORT_ALLOW_PLAINTEXT"
	// envStateExportRoot overrides the export root (primarily for tests).
	envStateExportRoot = env.EnvPrefix + "_STATE_EXPORT_ROOT"
)

// resolveStateExportRoot picks the directory to archive:
// EIGENINFERENCE_STATE_EXPORT_ROOT -> USER_PERSISTENT_DATA_PATH -> /mnt/disks/userdata.
func resolveStateExportRoot() string {
	return env.FirstNonEmpty(
		os.Getenv(envStateExportRoot),
		os.Getenv("USER_PERSISTENT_DATA_PATH"),
		"/mnt/disks/userdata",
	)
}

// envTrue trims the named variable and parses it with strconv.ParseBool.
// Invalid or unset values leave the state-export gate disabled.
func envTrue(name string) bool {
	b, _ := strconv.ParseBool(strings.TrimSpace(os.Getenv(name)))
	return b
}
