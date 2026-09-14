package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func cumulativeDelta(previous, current int64) int64 {
	if current <= 0 {
		return 0
	}
	if current >= previous {
		return current - previous
	}
	// The provider process restarted and reset its in-memory counters.
	return current
}

func applyHeartbeatStatsDelta(total *protocol.HeartbeatStats, previous, current protocol.HeartbeatStats) {
	total.RequestsServed += cumulativeDelta(previous.RequestsServed, current.RequestsServed)
	total.TokensGenerated += cumulativeDelta(previous.TokensGenerated, current.TokensGenerated)
	total.CancellationsReceived += cumulativeDelta(previous.CancellationsReceived, current.CancellationsReceived)
	total.CancellationsBeforeOutput += cumulativeDelta(previous.CancellationsBeforeOutput, current.CancellationsBeforeOutput)
	total.CancellationsPartialComplete += cumulativeDelta(previous.CancellationsPartialComplete, current.CancellationsPartialComplete)
	total.GenerationErrorsAfterOutput += cumulativeDelta(previous.GenerationErrorsAfterOutput, current.GenerationErrorsAfterOutput)
	total.ChunkEncryptionErrors += cumulativeDelta(previous.ChunkEncryptionErrors, current.ChunkEncryptionErrors)
	total.StreamClosedWithoutTerminal += cumulativeDelta(previous.StreamClosedWithoutTerminal, current.StreamClosedWithoutTerminal)
	total.CancelDuringModelLoad += cumulativeDelta(previous.CancelDuringModelLoad, current.CancelDuringModelLoad)
	total.UsageGaps += cumulativeDelta(previous.UsageGaps, current.UsageGaps)
	// System profiler cancel accountability counters (cumulative per session).
	total.CancelStagePreAcceptTotal += cumulativeDelta(previous.CancelStagePreAcceptTotal, current.CancelStagePreAcceptTotal)
	total.CancelStagePreEngineTotal += cumulativeDelta(previous.CancelStagePreEngineTotal, current.CancelStagePreEngineTotal)
	total.CancelStagePrefillTotal += cumulativeDelta(previous.CancelStagePrefillTotal, current.CancelStagePrefillTotal)
	total.CancelStageDecodeTotal += cumulativeDelta(previous.CancelStageDecodeTotal, current.CancelStageDecodeTotal)
	total.CancelStagePostTerminalTotal += cumulativeDelta(previous.CancelStagePostTerminalTotal, current.CancelStagePostTerminalTotal)
	total.TokensAfterCancelTotal += cumulativeDelta(previous.TokensAfterCancelTotal, current.TokensAfterCancelTotal)
	total.CancelAbortNSSum += cumulativeDelta(previous.CancelAbortNSSum, current.CancelAbortNSSum)
}

func mergeHeartbeatSessionStats(previous, current protocol.HeartbeatStats) protocol.HeartbeatStats {
	merged := current
	if merged.CancellationsReceived == 0 {
		merged.CancellationsReceived = previous.CancellationsReceived
	}
	if merged.CancellationsBeforeOutput == 0 {
		merged.CancellationsBeforeOutput = previous.CancellationsBeforeOutput
	}
	if merged.CancellationsPartialComplete == 0 {
		merged.CancellationsPartialComplete = previous.CancellationsPartialComplete
	}
	if merged.GenerationErrorsAfterOutput == 0 {
		merged.GenerationErrorsAfterOutput = previous.GenerationErrorsAfterOutput
	}
	if merged.ChunkEncryptionErrors == 0 {
		merged.ChunkEncryptionErrors = previous.ChunkEncryptionErrors
	}
	if merged.StreamClosedWithoutTerminal == 0 {
		merged.StreamClosedWithoutTerminal = previous.StreamClosedWithoutTerminal
	}
	if merged.CancelDuringModelLoad == 0 {
		merged.CancelDuringModelLoad = previous.CancelDuringModelLoad
	}
	if merged.UsageGaps == 0 {
		merged.UsageGaps = previous.UsageGaps
	}
	for _, f := range []struct{ cur, prev *int64 }{
		{&merged.CancelStagePreAcceptTotal, &previous.CancelStagePreAcceptTotal},
		{&merged.CancelStagePreEngineTotal, &previous.CancelStagePreEngineTotal},
		{&merged.CancelStagePrefillTotal, &previous.CancelStagePrefillTotal},
		{&merged.CancelStageDecodeTotal, &previous.CancelStageDecodeTotal},
		{&merged.CancelStagePostTerminalTotal, &previous.CancelStagePostTerminalTotal},
		{&merged.TokensAfterCancelTotal, &previous.TokensAfterCancelTotal},
		{&merged.CancelAbortNSSum, &previous.CancelAbortNSSum},
	} {
		if *f.cur == 0 {
			*f.cur = *f.prev
		}
	}
	return merged
}
