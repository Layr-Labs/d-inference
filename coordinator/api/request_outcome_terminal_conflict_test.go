package api

import (
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAccountingNativeResponseTerminalConflicts(t *testing.T) {
	for _, order := range [][]string{{"completed", "failed"}, {"failed", "completed"}, {"completed", "incomplete"}, {"completed", "completed"}} {
		for _, grouping := range []string{"separate_flushes", "coalesced_frames", "single_frame_group"} {
			for _, preamble := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%s/preamble=%t", strings.Join(order, "_"), grouping, preamble), func(t *testing.T) {
					tracker, pr := contentAccountingRequest("/v1/chat/completions")
					pr.Accounting.Observe("committed", "", 0)
					pr.Accounting.Observe("provider_complete", "", 0)
					w := httptest.NewRecorder()
					relay := newChatStreamRelay(pr, w, w, newRelayStamps(nil, tracker))
					if preamble {
						relay.handleChunk(`data: {"type":"response.created"}`)
					}
					var frames []string
					for _, status := range order {
						frames = append(frames, fmt.Sprintf("event: response.%s\ndata: {\"type\":\"response.%s\",\"response\":{\"status\":\"%s\"}}", status, status, status))
					}
					if grouping == "single_frame_group" {
						relay.handleChunk(strings.Join(frames, "\n\n"))
					} else {
						for _, frame := range frames {
							relay.handleChunk(frame)
							if grouping == "separate_flushes" {
								relay.flush()
							}
						}
					}
					relay.flush()
					tracker.Finish(200, false, false)
					row := tracker.Snapshot()
					conflict := order[0] != order[1]
					first := order[0]
					if first == "failed" {
						first = "error"
					}
					if row.EvidenceConflict != conflict || row.ResponseTerminal != first || !row.ResponseEgressCompleted {
						t.Fatalf("terminal evidence changed with flush grouping: %+v", row)
					}
					if conflict && (row.Termination != "unknown" || row.ResponseProgress == "completion_confirmed") {
						t.Fatalf("contradictory terminal presented as completion: %+v", row)
					}
					if !conflict && row.Termination != "completed" {
						t.Fatalf("matching terminal replay stopped completion: %+v", row)
					}
					for _, status := range order {
						if !strings.Contains(w.Body.String(), `"type":"response.`+status+`"`) {
							t.Fatal("accounting changed the emitted terminal frames")
						}
					}
				})
			}
		}
	}
}
