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
	// Required primary counters may reset to zero; omitted optional counters
	// retain the previous sample so a legacy heartbeat cannot double-count them.
	for _, f := range []struct{ cur, prev *int64 }{
		{&merged.CancellationsReceived, &previous.CancellationsReceived},
		{&merged.CancellationsBeforeOutput, &previous.CancellationsBeforeOutput},
		{&merged.CancellationsPartialComplete, &previous.CancellationsPartialComplete},
		{&merged.GenerationErrorsAfterOutput, &previous.GenerationErrorsAfterOutput},
		{&merged.ChunkEncryptionErrors, &previous.ChunkEncryptionErrors},
		{&merged.StreamClosedWithoutTerminal, &previous.StreamClosedWithoutTerminal},
		{&merged.CancelDuringModelLoad, &previous.CancelDuringModelLoad},
		{&merged.UsageGaps, &previous.UsageGaps},
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
