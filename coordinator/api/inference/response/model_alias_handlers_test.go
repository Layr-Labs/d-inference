package response

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	aliasFP8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	aliasQAT = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
)

// The headline guarantee at the function level: the consumer-facing model name
// is the alias, and the concrete build is never substituted in.
func TestConsumerModelAndChunkRewriteNeverLeakBuild(t *testing.T) {
	const build = aliasQAT
	const alias = "gemma-4-26b"

	pr := &registry.PendingRequest{Model: build, PublicModel: alias}
	if got := ConsumerModel(pr); got != alias {
		t.Fatalf("consumerModel = %q, want alias %q", got, alias)
	}
	compact := `data: {"id":"x","model":"` + build + `","choices":[]}`
	spaced := `data: {"id":"x","model": "` + build + `","choices":[]}`
	if out := rewriteChunkModel(compact, pr); strings.Contains(out, build) || !strings.Contains(out, alias) {
		t.Fatalf("compact chunk still leaks build: %q", out)
	}
	if out := rewriteChunkModel(spaced, pr); strings.Contains(out, build) || !strings.Contains(out, alias) {
		t.Fatalf("spaced chunk still leaks build: %q", out)
	}

	raw := &registry.PendingRequest{Model: build, PublicModel: build}
	if got := ConsumerModel(raw); got != build {
		t.Fatalf("raw consumerModel = %q, want %q", got, build)
	}
	if out := rewriteChunkModel(compact, raw); out != compact {
		t.Fatalf("raw-id chunk should be unchanged, got %q", out)
	}
	none := &registry.PendingRequest{Model: build}
	if got := ConsumerModel(none); got != build {
		t.Fatalf("empty PublicModel should fall back to build, got %q", got)
	}
}
