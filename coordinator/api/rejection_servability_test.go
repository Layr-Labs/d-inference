package api

import (
	"encoding/csv"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRejectionExportsPreserveUnknownServability(t *testing.T) {
	yes, no := true, false
	records := []store.RejectionRecord{
		{RequestID: "unknown"},
		{RequestID: "no", CouldHaveServed: &no},
		{RequestID: "yes", CouldHaveServed: &yes},
	}
	for _, filter := range []string{"true", "false"} {
		selected := filterRejectionRecords(records, "", "", filter)
		if len(selected) != 1 || selected[0].CouldHaveServed == nil || *selected[0].CouldHaveServed != (filter == "true") {
			t.Fatalf("filter %q includes unknown or wrong result: %+v", filter, selected)
		}
	}
	body, err := json.Marshal(records[0])
	if err != nil || !strings.Contains(string(body), `"could_have_served":null`) {
		t.Fatalf("unknown JSON: %s, %v", body, err)
	}
	rr := httptest.NewRecorder()
	if err := writeRejectionCSV(rr, records); err != nil {
		t.Fatal(err)
	}
	rows, err := csv.NewReader(strings.NewReader(rr.Body.String())).ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	column := -1
	for i, name := range rows[0] {
		if name == "could_have_served" {
			column = i
		}
	}
	if column < 0 {
		t.Fatal("missing servability column")
	}
	for i, want := range []string{"", "false", "true"} {
		if got := rows[i+1][column]; got != want {
			t.Fatalf("row %d servability = %q, want %q", i, got, want)
		}
	}
}
