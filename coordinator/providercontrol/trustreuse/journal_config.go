package trustreuse

import (
	"github.com/eigeninference/d-inference/coordinator/env"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	envTrustReuseRevocationJournal = env.EnvPrefix + "_TRUST_REUSE_REVOCATION_JOURNAL_PATH"
	trustReuseJournalFilename      = "trust-reuse-hard-untrust.v1.jsonl"
	trustReuseJournalVersion       = 1
	trustReuseJournalMaxEntries    = 4096
	trustReuseJournalMaxBytes      = 1 << 20
	trustReuseJournalMaxLineBytes  = 512
	trustReuseJournalLockTimeout   = 5 * time.Second
)

func JournalPathFromEnv() string {
	if override := strings.TrimSpace(os.Getenv(envTrustReuseRevocationJournal)); override != "" {
		return override
	}
	root := env.FirstNonEmpty(
		os.Getenv("USER_PERSISTENT_DATA_PATH"),
		"/mnt/disks/userdata",
	)
	return filepath.Join(root, "coordinator", trustReuseJournalFilename)
}
