package api

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestFilterRejectionRecordsExcludesUncomputedCounterfactual: a rejection
// row whose servability walk was skipped (candidate_count = -1, the marker
// the sink writes when the routing scans are saturated) is neither a
// could_have_served=true nor a could_have_served=false row for the admin
// API — its false is the marker's default, not a verdict. Unfiltered reads
// still return it. Before the change ?could_have_served=false returned it as
// a real "no capacity existed" row.
func TestFilterRejectionRecordsExcludesUncomputedCounterfactual(t *testing.T) {
	rows := []store.RejectionRecord{
		{ReasonCode: "routing_saturated", RequestedModel: "m", CandidateCount: -1, CouldHaveServed: false},
		{ReasonCode: "routing_saturated", RequestedModel: "m", CandidateCount: 0, CouldHaveServed: false},
		{ReasonCode: "routing_saturated", RequestedModel: "m", CandidateCount: 3, CouldHaveServed: true},
	}
	counts := func(couldHaveServed string) (n int, uncomputed int) {
		out := filterRejectionRecords(rows, "", "", couldHaveServed)
		for _, rec := range out {
			if rec.CandidateCount < 0 {
				uncomputed++
			}
		}
		return len(out), uncomputed
	}
	if n, u := counts("false"); n != 1 || u != 0 {
		t.Fatalf("could_have_served=false returned %d rows (%d uncomputed), want exactly the candidate_count=0 row", n, u)
	}
	if n, u := counts("true"); n != 1 || u != 0 {
		t.Fatalf("could_have_served=true returned %d rows (%d uncomputed), want exactly the candidate_count=3 row", n, u)
	}
	if n, u := counts(""); n != 3 || u != 1 {
		t.Fatalf("unfiltered returned %d rows (%d uncomputed), want all 3 incl. the marker row", n, u)
	}
	// Reason/model filters still apply on their own and combine with it.
	if out := filterRejectionRecords(rows, "routing_saturated", "m", "false"); len(out) != 1 || out[0].CandidateCount != 0 {
		t.Fatalf("combined filter = %+v, want the single computed false row", out)
	}
}
