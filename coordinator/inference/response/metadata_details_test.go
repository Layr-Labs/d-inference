package response

import (
	"strings"
	"testing"
)

func TestStripSSEDoneEventsPreservesSiblingEvents(t *testing.T) {
	t.Parallel()
	input := "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" +
		"event: done\nid: provider-terminal\ndata: [DONE]\n\n"

	got, removed := stripSSEDoneEvents(input)
	if !removed {
		t.Fatal("expected provider terminator to be removed")
	}
	if strings.Contains(got, "[DONE]") || strings.Contains(got, "provider-terminal") {
		t.Fatalf("provider terminator survived: %s", got)
	}
	if !strings.Contains(got, `"content":"hi"`) {
		t.Fatalf("sibling content event was removed: %s", got)
	}

	got, removed = stripSSEDoneEvents("\uFEFFdata: [DONE]\n\n")
	if !removed || strings.TrimSpace(got) != "" {
		t.Fatalf("BOM-prefixed provider terminator survived: %q", got)
	}
}
