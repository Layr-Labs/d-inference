package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestDeadlineUnboundedReasonWireVocabulary(t *testing.T) {
	data, err := os.ReadFile("testdata/deadline_unbounded_reasons.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Reasons []DeadlineUnboundedReason `json:"reasons"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Reasons) != 24 {
		t.Fatalf("expected 23 engine causes and other, got %d", len(fixture.Reasons))
	}
	seen := map[DeadlineUnboundedReason]bool{}
	for _, reason := range fixture.Reasons {
		if seen[reason] || !reason.Valid() || reason.Fold() != reason {
			t.Fatalf("duplicate or invalid wire reason %q", reason)
		}
		seen[reason] = true
		data, err := json.Marshal(DeadlineDecision{Projection: DeadlineProjectionUnbounded, UnboundedReason: reason})
		if err != nil {
			t.Fatal(err)
		}
		var decoded struct {
			Reason string `json:"unbounded_reason"`
		}
		if err := json.Unmarshal(data, &decoded); err != nil || decoded.Reason != string(reason) {
			t.Fatalf("reason lost on wire: %s, %v", data, err)
		}
	}
	if DeadlineUnboundedReason("").Fold() != "" {
		t.Fatal("missing historical reason must remain missing")
	}
	for _, value := range []DeadlineUnboundedReason{"future_reason", "FREE_TEXT", "capacity_not_guaranteed\n"} {
		if value.Valid() || value.Fold() != DeadlineUnboundedOther {
			t.Fatalf("unrecognized reason retained: %q", value)
		}
	}
}
