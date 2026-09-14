package cachedirectory

import (
	"time"
)

const (
	DefaultTTL                = 10 * time.Minute
	DefaultMaxHolders         = 4
	AttemptTTL                = 2 * time.Minute
	InFlightAttemptTTL        = 2 * time.Hour
	SweepInterval             = 30 * time.Second
	MaxEntries                = 10_000
	MaxAttempts               = 50_000
	MaxReceiptTokens          = 1_000_000
	MaxStageMs                = 10 * 60 * 1000.0
	MemoryTTL                 = 30 * time.Second
	MaxCheckpointReadyAnchors = 16
)

const CacheRoutingOn = "on"
