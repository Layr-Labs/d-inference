package api

import "github.com/eigeninference/d-inference/coordinator/registry"

// This counts selections/attempts, not requests saved or HTTP successes. The
// persisted request profile joins the forecast to actual attempt outcomes.
func (s *Server) emitFirstContentRouting(model string, d registry.RoutingDecision) {
	if d.FirstContent.Status == "" {
		return
	}
	tags := []string{"model:" + model, "mode:" + d.FirstContentMode,
		"status:" + d.FirstContent.Status, "reason:" + d.FirstContent.Reason}
	s.ddIncr("routing.first_content.selection", tags)
	if d.ScanCount > 0 {
		s.ddHistogram("routing.first_content.feasible_candidates", float64(d.FirstContentFeasibleCount), tags)
		if d.FirstContent.Status != "feasible" && d.FirstContentFeasibleCount > 0 {
			s.ddIncr("routing.first_content.alternative", tags)
		}
	}
	if d.FirstContent.PredictedMs > 0 {
		s.ddHistogram("routing.first_content.predicted_ms", d.FirstContent.PredictedMs, tags)
		s.ddHistogram("routing.first_content.remaining_ms", d.FirstContent.BudgetMs, tags)
	}
}
