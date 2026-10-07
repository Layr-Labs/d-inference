package inference

import (
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
)

func (s *Owner) recordToolConstraintMetric(mode inreq.ToolChoiceMode, outcome string) {
	if mode == "" {
		mode = "invalid"
	}
	s.observation.Incr("inference.tool_constraint", []string{
		"mode:" + string(mode),
		"outcome:" + outcome,
	})
}
