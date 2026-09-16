package releases

import "time"

const (
	maxReleaseRegisterBodyBytes = 64 * 1024
	maxReleaseArtifactBytes     = 2 << 30 // 2 GiB
	maxReleaseProviderBinBytes  = 512 << 20
	releaseArtifactTimeout      = 2 * time.Minute
)
