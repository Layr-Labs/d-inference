package attempt

import (
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/profile"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Content is the first-content handoff to the consumer response writer. A
// terminal consumed alongside buffered content must follow that content.
type Content struct {
	FirstChunk   string
	InitialError *protocol.InferenceErrorMessage
}

type ContentCommitDependencies struct {
	Registry  *registry.Registry
	Logger    *slog.Logger
	Calibrate func(*registry.PendingRequest)
}

type ContentCommitter struct {
	deps ContentCommitDependencies
}

func NewContentCommitter(deps ContentCommitDependencies) *ContentCommitter {
	return &ContentCommitter{deps: deps}
}

// Commit stamps the actual content instant before either the dispatch goroutine
// or the provider read loop can publish this committed attempt's route outcome.
func (c *ContentCommitter) Commit(rp *registry.RequestProfile, pr *registry.PendingRequest, heldCount int, chunk string) Content {
	pr.MarkFirstChunkArrived()
	pr.MarkFirstContentArrived()
	profile.StampFirstContent(rp, pr, heldCount)
	// Only this attempt may supply handleComplete's fallback content stamp, not
	// a late abandoned attempt that shares the request's Timing.
	pr.MarkContentCommitted()
	c.deps.Calibrate(pr)
	// First content also vouches for capacity. Stamp the rate outcome before
	// scheduling the recorder so completion cannot double-count it, and carry
	// observation time across the registry-lock wait to preserve later rejects.
	pr.MarkRateOutcomeCounted()
	providerID, model := pr.ProviderID, pr.Model
	observedAt := pr.FirstContentAtSafe()
	if observedAt.IsZero() {
		observedAt = time.Now()
	}
	saferun.Go(c.deps.Logger, "api.recordCapacityAccept", func() {
		c.deps.Registry.RecordCapacityAcceptObserved(providerID, model, observedAt, true)
	})
	return Content{FirstChunk: chunk}
}

// Buffered gives already-buffered, on-time content precedence over a ready
// terminal channel: Go select does not preserve provider frame order across
// ChunkCh and ErrorCh.
func (c *ContentCommitter) Buffered(rp *registry.RequestProfile, pr *registry.PendingRequest, held *[]string, msg protocol.InferenceErrorMessage) *Content {
	chunk, ok := firstcontent.DrainReadyFirstContent(pr, held)
	if !ok {
		return nil
	}
	content := c.Commit(rp, pr, len(*held), chunk.Data)
	content.InitialError = &msg
	return &content
}
