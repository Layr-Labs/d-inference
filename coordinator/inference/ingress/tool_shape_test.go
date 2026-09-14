package ingress

import (
	"encoding/json"
	"testing"
)

func TestRequestHasTools(t *testing.T) {
	cases := []struct {
		name string
		body string
		want bool
	}{
		{name: "absent", body: `{"model":"m","messages":[]}`, want: false},
		{name: "empty array", body: `{"model":"m","tools":[]}`, want: false},
		{name: "non-empty array", body: `{"model":"m","tools":[{"type":"function","function":{"name":"f"}}]}`, want: true},
		{name: "two tools", body: `{"model":"m","tools":[{"type":"function"},{"type":"function"}]}`, want: true},
		{name: "wrong type string", body: `{"model":"m","tools":"function"}`, want: false},
		{name: "wrong type object", body: `{"model":"m","tools":{"type":"function"}}`, want: false},
		{name: "wrong type number", body: `{"model":"m","tools":3}`, want: false},
		{name: "null", body: `{"model":"m","tools":null}`, want: false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var parsed map[string]any
			if err := json.Unmarshal([]byte(tc.body), &parsed); err != nil {
				t.Fatalf("unmarshal test body: %v", err)
			}
			if got := requestHasTools(parsed); got != tc.want {
				t.Errorf("requestHasTools(%s) = %v, want %v", tc.body, got, tc.want)
			}
		})
	}
}
