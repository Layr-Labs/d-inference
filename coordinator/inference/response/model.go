package response

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"strings"
)

// consumerModel returns the model name to echo back to the consumer: the public
// alias they requested when set, otherwise the concrete build id (raw-id
// requests and any internal caller that didn't populate PublicModel).
func ConsumerModel(pr *registry.PendingRequest) string {
	if pr.PublicModel != "" {
		return pr.PublicModel
	}
	return pr.Model
}

// rewriteChunkModel replaces the concrete build id in a streamed SSE chunk's
// "model" field with the public alias the consumer requested, so streaming
// responses never expose the underlying build/quant. No-op when the request
// used a raw build id (PublicModel == Model) or no alias was set. Uses a
// precise key+value string replace (both compact and spaced JSON forms) to
// avoid parsing every chunk on the hot path.
func rewriteChunkModel(chunk string, pr *registry.PendingRequest) string {
	if pr.PublicModel == "" || pr.PublicModel == pr.Model {
		return chunk
	}
	chunk = strings.ReplaceAll(chunk, `"model":"`+pr.Model+`"`, `"model":"`+pr.PublicModel+`"`)
	chunk = strings.ReplaceAll(chunk, `"model": "`+pr.Model+`"`, `"model": "`+pr.PublicModel+`"`)
	return chunk
}
