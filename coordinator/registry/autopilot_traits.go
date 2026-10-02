package registry

import "github.com/eigeninference/d-inference/coordinator/registry/autopilot"

// AutopilotRequirements projects all hard routing traits without retaining tool
// names, output policy or retry preferences in aggregate demand.
func (t RequestTraits) AutopilotRequirements(vision bool) autopilot.Requirements {
	return autopilot.Requirements{
		RequiresVision: vision, HasTools: t.HasTools,
		RequiresToolConstraint:   t.RequiresToolConstraint,
		RequiresNativeMediaTools: t.RequiresNativeMediaTools,
		ToolChoiceMode:           t.ToolChoiceMode, MinPrefixCacheProtocol: t.MinPrefixCacheProtocol,
	}
}

func requestTraitsForAutopilot(r autopilot.Requirements) RequestTraits {
	return RequestTraits{
		HasTools: r.HasTools, RequiresToolConstraint: r.RequiresToolConstraint,
		RequiresNativeMediaTools: r.RequiresNativeMediaTools,
		ToolChoiceMode:           r.ToolChoiceMode, MinPrefixCacheProtocol: r.MinPrefixCacheProtocol,
	}
}
