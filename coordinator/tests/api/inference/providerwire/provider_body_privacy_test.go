package providerwire_test

import (
	"bytes"
	"fmt"
	"testing"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	. "github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func assertCallerIdentityAbsent(t *testing.T, body []byte) {
	t.Helper()
	parsed, err := inreq.DecodeInferenceJSONObject(body)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"user", "metadata"} {
		if _, exists := parsed[field]; exists {
			t.Errorf("provider-bound request retains top-level caller %q", field)
		}
	}
}

func TestProviderBodyPrivacyCandidateBodyParity(t *testing.T) {
	srv, reg, st := newBenchServer(t)
	testkit.RegisterBuildsProvider(reg, "privacy-memo", benchDesiredBuild, benchPreviousBuild)
	for _, fields := range []string{
		`"messages":[{"role":"user","content":"hello"}],"max_tokens":16`,
		`"input":"hello","max_output_tokens":16`,
	} {
		body := fmt.Sprintf(`{"model":%q,%s,"user":"synthetic","metadata":{"conversation_id":"synthetic"}}`, benchAlias, fields)
		providerBody, parsed, defaults, model, reasoning, responses, _ := runChatRewrites(t, srv, reg, st, body, false)
		fresh, err := CandidateBody(st, parsed, defaults, model, false, reasoning, responses)
		if err != nil {
			t.Fatal(err)
		}
		assertCallerIdentityAbsent(t, fresh)
		if !bytes.Equal(providerBody, fresh) {
			t.Fatal("handler and candidate/planning preparation differ")
		}
	}
}
