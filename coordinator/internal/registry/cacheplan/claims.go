package cacheplan

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Claims freezes the expected receipt hashes. Neither a request-local plan nor
// a directory lookup can mutate the accepted attempt's boundary bindings.
type Claims struct{ expected map[int]string }

func NewClaims(boundaries []protocol.PrefixCacheAnchor, blockSize uint32, prompt protocol.PrefixCacheAnchor) (*Claims, bool) {
	expected := make(map[int]string, len(boundaries))
	for _, boundary := range boundaries {
		if !cachepolicy.Anchor(boundary, blockSize) || boundary.TokenCount > prompt.TokenCount {
			return nil, false
		}
		if _, duplicate := expected[boundary.TokenCount]; duplicate {
			return nil, false
		}
		expected[boundary.TokenCount] = boundary.ChainHash
	}
	return &Claims{expected: expected}, true
}

func (c *Claims) Matches(anchor protocol.PrefixCacheAnchor) bool {
	return c != nil && c.expected[anchor.TokenCount] == anchor.ChainHash
}
