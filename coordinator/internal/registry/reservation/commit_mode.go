package reservation

import (
	"log/slog"
	"os"
	"strings"
)

// CommitMode selects shared or fleet-wide serialization of a reservation debit.
type CommitMode uint8

const (
	// Shared retains the registry read lease while the provider lock protects
	// the fresh snapshot, admission recheck, probe claim and pending debit.
	Shared CommitMode = iota
	// Global restores fleet-wide write serialization as a kill switch.
	Global
)

const CommitModeEnv = "EIGENINFERENCE_RESERVE_COMMIT_MODE"

// LoadCommitMode reads the restart-scoped policy and reports unknown values.
func LoadCommitMode(logger *slog.Logger) CommitMode {
	raw := os.Getenv(CommitModeEnv)
	mode, known := ParseCommitMode(raw)
	if !known && logger != nil {
		logger.Warn("unknown reserve commit mode; using shared",
			"env", CommitModeEnv, "value", raw)
	}
	return mode
}

func ParseCommitMode(raw string) (mode CommitMode, known bool) {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", "shared":
		return Shared, true
	case "global":
		return Global, true
	default:
		return Shared, false
	}
}

func (m CommitMode) String() string {
	if m == Global {
		return "global"
	}
	return "shared"
}
