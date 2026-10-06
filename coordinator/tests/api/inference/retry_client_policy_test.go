package inference_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestShouldStopFailover_ClientError400(t *testing.T) {
	c := retry.New(retry.Config{Model: "m"})
	d := c.Decide(protocol.InferenceErrorMessage{StatusCode: 400, Error: "assistant message contains multiple tool_calls; Harmony supports one tool call per assistant message"}, 0)
	if !d.Stop {
		t.Fatal("a provider 400 must stop failover on the first attempt")
	}
	if d.ClientStatusCode == 0 || d.ClientStatusCode != 400 {
		t.Fatalf("terminalClientError must latch with code 400; got latched=%v code=%d", d.ClientStatusCode != 0, d.ClientStatusCode)
	}
}

func TestShouldStopFailover_413And415(t *testing.T) {
	for _, code := range []int{413, 415} {
		c := retry.New(retry.Config{Model: "m"})
		d := c.Decide(protocol.InferenceErrorMessage{StatusCode: code}, 0)
		if !d.Stop {
			t.Fatalf("a provider %d must stop failover", code)
		}
		if d.ClientStatusCode != code {
			t.Fatalf("code %d must latch; got %d", code, d.ClientStatusCode)
		}
	}
}

// 422 (invalidResponseFormatOutput) is EXCLUDED from the stop set: it can be a
// model-output-validation fault that recovers on retry at temp>0, so it must keep
// failing over rather than be returned once.
func TestShouldStopFailover_422FailsOver(t *testing.T) {
	c := retry.New(retry.Config{Model: "m"})
	d := c.Decide(protocol.InferenceErrorMessage{StatusCode: 422, Error: "model output was not valid JSON"}, 0)
	if d.Stop {
		t.Fatal("422 must fail over (may recover on retry), not stop")
	}
	if d.ClientStatusCode != 0 {
		t.Fatal("422 must NOT latch a terminal client error")
	}
}

// Reviewer-correction regression guard: 404 "model not loaded" is a cold-miss
// that MUST keep failing over (it also matches the "not loaded" capacity marker),
// so it must NOT be treated as a terminal client error.
func TestShouldStopFailover_ColdMiss404StillFailsOver(t *testing.T) {
	c := retry.New(retry.Config{Model: "m"})
	d := c.Decide(protocol.InferenceErrorMessage{StatusCode: 404, Error: "Model 'm' is not loaded on this provider"}, 0)
	if d.Stop {
		t.Fatal("404 cold-miss must fail over to a provider that has the model loaded, not stop")
	}
	if d.ClientStatusCode != 0 {
		t.Fatal("404 must NOT latch a terminal client error")
	}
}

// 429 queue-full is transient capacity and must remain failover-able.
func TestShouldStopFailover_QueueFull429StillFailsOver(t *testing.T) {
	c := retry.New(retry.Config{Model: "m"})
	d := c.Decide(protocol.InferenceErrorMessage{StatusCode: 429, Error: "request rejected: queue full"}, 0)
	if d.Stop {
		t.Fatal("429 queue-full must fail over (transient capacity), not stop")
	}
	if d.ClientStatusCode != 0 {
		t.Fatal("429 must NOT latch a terminal client error")
	}
}

// A client-shape 4xx observed from a speculative race LOSER (whose code is never
// written to d.lastErr) must latch via latchDeterministicLoser and then stop the
// loop — otherwise the storm resumes through the survivor's later transient error.
func TestLatchDeterministicLoser_ClientError400(t *testing.T) {
	c := retry.New(retry.Config{Model: "m"})
	d, _ := c.RecordLoser(protocol.InferenceErrorMessage{StatusCode: 400, Error: "invalid tool payload", FailureCode: protocol.FailureCodeInvalidRequest}, 0)
	if d.ClientStatusCode == 0 || d.ClientStatusCode != 400 {
		t.Fatalf("race-loser 400 must latch terminalClientError; got latched=%v code=%d", d.ClientStatusCode != 0, d.ClientStatusCode)
	}
	// Survivor reports a transient error that alone would NOT stop failover.
	if !c.Decide(protocol.InferenceErrorMessage{StatusCode: 0, Error: "request rejected: queue full"}, 0).Stop {
		t.Fatal("a latched race-loser client error must stop failover regardless of the survivor's error")
	}
}

// Kill switch: with the stop disabled, a 400 falls through to the legacy
// string-only classifyRejection path (here: not capacity → keep failing over).
func TestClientErrorStop_KillSwitch(t *testing.T) {
	c := retry.New(retry.Config{Model: "m", DisableClientErrorStop: true})
	d := c.Decide(protocol.InferenceErrorMessage{StatusCode: 400, Error: "invalid tool payload"}, 0)
	if d.Stop {
		t.Fatal("with the kill switch on, a 400 must not trigger the StatusCode stop")
	}
	if d.ClientStatusCode != 0 {
		t.Fatal("kill switch must not latch terminalClientError")
	}
}
