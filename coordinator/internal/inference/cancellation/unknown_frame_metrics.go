package cancellation

import (
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Unknown-frame instrumentation (zombie-stream amplifier visibility).
//
// A provider that keeps generating into a request the coordinator already
// abandoned (consumer gone, first-chunk timeout, settled) sends chunk /
// complete / error frames whose request_id matches no pending state. The
// coordinator logs each one and (throttled) re-sends a cancel, but during the
// 2026-08-31 cascade ~65K such frames in 10 minutes were invisible on any
// panel: inference.zombie_stream_cancel is throttled and untagged. This
// counter is the raw, unthrottled count, tagged by the FRAME KIND and the
// provider's binary version — bounded vocabularies — so a zombie wave can be
// pinned to a release. It never carries the provider id or the request id.
const (
	MetricUnknownFrames        = "inference.unknown_frames"
	MetricUnknownFramesCounter = "inference_unknown_frames_total"

	UnknownFrameKindChunk    = "chunk"
	UnknownFrameKindComplete = "complete"
	UnknownFrameKindError    = "error"
)

// emitUnknownFrame counts one provider frame for an unknown request id.
func (s *Controller) EmitUnknownFrame(kind string, provider *registry.Provider) {
	if s == nil {
		return
	}
	version := observation.ProviderVersionTag(provider)
	if s.Observation.
		Metrics() != nil {
		s.Observation.
			Metrics().IncCounter(MetricUnknownFramesCounter,
			observation.MetricLabel{Name: "kind", Value: kind}, observation.MetricLabel{Name: "provider_version", Value: version})
	}
	if s.Observation.
		Datadog() == nil {
		return
	}
	s.Observation.
		Incr(MetricUnknownFrames, []string{"kind:" + kind, "provider_version:" + version})
}
