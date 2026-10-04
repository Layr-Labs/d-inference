package promptproof

import (
	"time"
)

type Config struct {
	BinaryPath      string
	ArtifactRoot    string
	VectorsPath     string
	Duration        time.Duration
	QPS             int
	MaxRSSMiB       int
	MaxRSSGrowthMiB int
}
