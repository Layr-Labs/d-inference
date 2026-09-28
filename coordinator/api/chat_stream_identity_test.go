package api

import "testing"

func TestChatStreamIdentityObservation(t *testing.T) {
	for _, test := range []struct {
		name, wire string
		created    bool
	}{
		{"bare", `{"id":"native","object":"chat.completion.chunk","created":123,"choices":[]}`, true},
		{"decorated-multiline", "event: message\r\nid: ignored\r\ndata: {\"id\":\"native\",\r\ndata: \"object\":\"chat.completion.chunk\",\"created\":123,\"choices\":[]}", true},
		{"coalesced-and-escaped", ": {\"id\":\"comment\"}\n\ndata: {\"choices\":[{\"delta\":{\"id\":\"nested\"}}]}\n\ndata: {\"id\":\"nat\\u0069ve\",\"created\":123,\"choices\":[]}", true},
		{"created-null", `data: {"id":"native","created":null,"choices":[]}`, false},
		{"created-invalid", `data: {"id":"native","created":"wrong","choices":[]}`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			var identity chatStreamIdentity
			identity.observe(test.wire)
			if identity.id != "native" || (identity.created != nil) != test.created {
				t.Fatalf("unexpected identity %+v", identity)
			}
			if identity.created != nil && *identity.created != 123 {
				t.Fatal("creation time changed")
			}
			identity.observe(`data: {"id":"later","created":456,"choices":[]}`)
			if identity.id != "native" {
				t.Fatal("first provider identity overwritten")
			}
		})
	}
	for _, invalid := range []string{
		`data: {"object":"response","id":"responses-id","choices":[]}`,
		`data: {"id":42,"choices":[]}`, `data: {"id":"","choices":[]}`,
		`data: {"metadata":{"id":"nested"},"choices":[]}`, `data: {"id":"not-chat"}`,
		`data: {"id":"incomplete"`, `: data: {"id":"comment","choices":[]}`,
	} {
		var identity chatStreamIdentity
		identity.observe(invalid)
		if identity.id != "" {
			t.Fatalf("non-envelope id trusted: %q", invalid)
		}
	}
}
