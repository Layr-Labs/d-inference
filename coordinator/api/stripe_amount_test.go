package api

import "testing"

func TestParseUSDCents(t *testing.T) {
	tests := []struct {
		input string
		want  int64
	}{
		{input: "0.50", want: 50},
		{input: "1", want: 100},
		{input: "1.2", want: 120},
		{input: "123.45", want: 12345},
		{input: " 5.00 ", want: 500},
	}
	for _, test := range tests {
		t.Run(test.input, func(t *testing.T) {
			got, err := parseUSDCents(test.input)
			if err != nil {
				t.Fatal(err)
			}
			if got != test.want {
				t.Fatalf("parseUSDCents(%q) = %d, want %d", test.input, got, test.want)
			}
		})
	}
}

func TestParseUSDCentsRejectsAmbiguousNumbers(t *testing.T) {
	for _, input := range []string{
		"", "0", "-1", "+1", ".50", "1.", "1.001", "1e3", "NaN", "Inf",
		"92233720368547759.00",
	} {
		t.Run(input, func(t *testing.T) {
			if _, err := parseUSDCents(input); err == nil {
				t.Fatalf("parseUSDCents(%q) succeeded", input)
			}
		})
	}
}
