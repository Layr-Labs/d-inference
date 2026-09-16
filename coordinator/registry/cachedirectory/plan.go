package cachedirectory

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/cacheattempt"
)

// Plan projects the existing immutable exact-boundary request facts.
type Plan struct {
	// Identity of the configuration that authenticated these exact boundaries.
	Generation         *cacheattempt.Generation
	ModelAggregateHash string
	PromptContractID   string
	CacheScope         string
	PromptTokenCount   int
	Boundaries         []protocol.PrefixCacheAnchor
}

func (p Plan) Present() bool {
	return p.ModelAggregateHash != "" &&
		p.PromptContractID != "" &&
		p.CacheScope != "" &&
		p.PromptTokenCount > 0 &&
		len(p.Boundaries) > 0
}
