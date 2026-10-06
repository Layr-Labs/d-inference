package autopilot

import "maps"

// WithQueuedDemand projects current qualified waiters into the same cohorts as
// terminal demand. It never increments logical arrivals or persists queue data.
// The caller passes only public, unrestricted, live requests without content.
func WithQueuedDemand(history map[string]DemandView, queued []DemandSample) map[string]DemandView {
	return withLiveDemand(history, queued, false)
}

// WithActiveDemand accounts for validated public in-flight work before its
// terminal observation arrives. It preserves the same eligibility cohorts.
func WithActiveDemand(history map[string]DemandView, active []DemandSample) map[string]DemandView {
	return withLiveDemand(history, active, true)
}

func withLiveDemand(history map[string]DemandView, samples []DemandSample, active bool) map[string]DemandView {
	out := maps.Clone(history)
	if out == nil {
		out = map[string]DemandView{}
	}
	for _, sample := range samples {
		if !sample.ValidEnvelope() || sample.FirstContentDeadline < 0 {
			continue
		}
		key := ShapeKey(sample)
		d := out[key]
		d.Requirements = sample.Requirements
		firstLive := d.Queued+d.InFlight == 0 && d.Requests == 0
		if active {
			d.InFlight++
		} else {
			d.Queued++
		}
		d.PromptTokens = max(d.PromptTokens, sample.PromptTokens)
		d.TailPromptTokens = max(d.TailPromptTokens, sample.PromptTokens)
		d.RequestedMaxTokens = max(d.RequestedMaxTokens, sample.RequestedMaxTokens)
		d.OutputTokens = max(d.OutputTokens, sample.RequestedMaxTokens)
		deadline := sample.FirstContentDeadline.Seconds()
		if sample.DeadlineKnown && (!d.DeadlineKnown || firstLive || deadline < d.DeadlineSeconds) {
			d.DeadlineSeconds = deadline
		}
		d.DeadlineKnown = sample.DeadlineKnown
		if sample.ReceivedAt.After(d.LastDemand) {
			d.LastDemand = sample.ReceivedAt
		}
		out[key] = d
	}
	return out
}
