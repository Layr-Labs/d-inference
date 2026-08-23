package main

import (
	"testing"
	"time"
)

func TestParsePrefillKeepaliveInterval(t *testing.T) {
	tests := []struct {
		name    string
		value   string
		want    time.Duration
		wantErr bool
	}{
		{name: "unset uses default", want: 5 * time.Second},
		{name: "override", value: "750ms", want: 750 * time.Millisecond},
		{name: "zero disables", value: "0", want: 0},
		{name: "invalid uses default", value: "soon", want: 5 * time.Second, wantErr: true},
		{name: "negative uses default", value: "-1s", want: 5 * time.Second, wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parsePrefillKeepaliveInterval(tc.value)
			if (err != nil) != tc.wantErr {
				t.Fatalf("error = %v, wantErr %v", err, tc.wantErr)
			}
			if got != tc.want {
				t.Fatalf("interval = %s, want %s", got, tc.want)
			}
		})
	}
}
