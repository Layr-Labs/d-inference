package operations

import "testing"

func TestCSVCellGuardsFormulaPrefixes(t *testing.T) {
	for _, in := range []string{"=HYPERLINK(1)", "+1", "-1", "@x", "\tx", "\rx"} {
		if got := csvCell(in); got != "'"+in {
			t.Fatalf("csvCell(%q) = %q", in, got)
		}
	}
	if csvCell("plain") != "plain" || csvCell("") != "" {
		t.Fatal("plain cells untouched")
	}
}
