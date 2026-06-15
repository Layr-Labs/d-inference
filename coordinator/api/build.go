package api

// Build metadata is filled by release builds via -ldflags. Safe defaults keep
// local and test builds identifiable without requiring build-time injection.
var (
	BuildVersion = "dev"
	BuildCommit  = "unknown"
	BuildDate    = "unknown"
)
