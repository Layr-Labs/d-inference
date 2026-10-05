// Package cachepolicy validates cache capability, receipt shape and optional
// telemetry values. These detached values never supply cache proof themselves.
package cachepolicy

const (
	MaxReceiptTokens          = 1_000_000
	MaxStageMs                = 10 * 60 * 1000.0
	MaxCheckpointReadyAnchors = 16
)
