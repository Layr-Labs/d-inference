package inference_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestFirstContentPreflightRetainsOriginalClockAndCalibration(t *testing.T) {
	received := time.Now().Add(-2 * time.Second)
	p := firstcontent.Preflight{
		EstimatedPromptTokens: 1000, RequestedMaxTokens: 16000,
		Deadline: 10 * time.Second, ReceivedAt: received,
		Calibration: estimate.NewContextCalibration(),
		CachePlanForModel: func(model string) registry.CachePlan {
			return registry.CachePlan{PromptTokenCount: 1536}
		},
	}
	pr := p.Request("gpt-oss", registry.RequestTraits{HasTools: true})
	if !pr.FirstContentDeadline.Equal(received.Add(p.Deadline)) {
		t.Fatal("preflight reset the original request clock")
	}
	if pr.EstimatedPromptTokens != 1000 || pr.RequestedMaxTokens != 16000 || pr.FirstContentPromptTokens != p.Calibration.ContextPromptTokens("gpt-oss", 1000) {
		t.Fatal("advisory prompt calibration changed physical reservation inputs")
	}
	if pr.CachePlan.PromptTokenCount != 1536 || !pr.Traits.HasTools {
		t.Fatal("preflight lost exact plan or request traits")
	}
	if remaining := p.RemainingBudget(); remaining > 8*time.Second || remaining <= 7*time.Second {
		t.Fatalf("remaining budget=%v, want original clock minus elapsed processing", remaining)
	}
	p.ReceivedAt = time.Now().Add(-20 * time.Second)
	if p.RemainingBudget() != time.Nanosecond {
		t.Fatal("expired positive deadline must not become an exempt zero deadline")
	}
	p.Deadline = 0
	if !p.Request("gpt-oss", registry.RequestTraits{}).FirstContentDeadline.IsZero() || p.RemainingBudget() != 0 {
		t.Fatal("preflight added a deadline to an exempt request")
	}
}
