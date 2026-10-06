package autopilot

import "fmt"

// Requirements contains only hard routing eligibility. Free-form tool names,
// request content, account identity and soft retry preferences never enter it.
type Requirements struct {
	RequiresVision           bool
	HasTools                 bool
	RequiresToolConstraint   bool
	RequiresNativeMediaTools bool
	ToolChoiceMode           string
	MinPrefixCacheProtocol   int
}

func toolChoiceClass(mode string) (int, bool) {
	switch mode {
	case "":
		return 0, true
	case "auto":
		return 1, true
	case "none":
		return 2, true
	case "required":
		return 3, true
	case "named":
		return 4, true
	default:
		return 5, false
	}
}

func (r Requirements) valid() bool {
	_, known := toolChoiceClass(r.ToolChoiceMode)
	return known && r.MinPrefixCacheProtocol >= 0
}

func (r Requirements) cohortKey() string {
	flags := 0
	for i, enabled := range []bool{r.RequiresVision, r.HasTools, r.RequiresToolConstraint, r.RequiresNativeMediaTools} {
		if enabled {
			flags |= 1 << i
		}
	}
	choice, _ := toolChoiceClass(r.ToolChoiceMode)
	return fmt.Sprintf("%d:%d:%d", flags, choice, r.MinPrefixCacheProtocol)
}

func (r *Requirements) merge(other Requirements) {
	r.RequiresVision = r.RequiresVision || other.RequiresVision
	r.HasTools = r.HasTools || other.HasTools
	r.RequiresToolConstraint = r.RequiresToolConstraint || other.RequiresToolConstraint
	r.RequiresNativeMediaTools = r.RequiresNativeMediaTools || other.RequiresNativeMediaTools
	r.MinPrefixCacheProtocol = max(r.MinPrefixCacheProtocol, other.MinPrefixCacheProtocol)
	// Exact within a cohort. Model-wide summaries conservatively retain the
	// special none-version floor when any member requires it.
	if r.ToolChoiceMode == "" || other.ToolChoiceMode == "none" {
		r.ToolChoiceMode = other.ToolChoiceMode
	}
}
