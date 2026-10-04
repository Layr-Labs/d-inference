package identity

import "time"

type proofRecord struct {
	CoveredUntil time.Time // verified same-process continuity, never an APNs refresh
	At           time.Time
	Version      string
	Token        string // empty on legacy rows
	NodeKey      string // registration X25519 process key
	BinaryHash   string // SE-attested binary identity
}

// Push ownership follows the stable SE key across WebSocket reconnects.
type pushChallenge struct {
	Nonce, Token, NodeKey string
	At                    time.Time
	Accepted, Counted     bool // push-reply diagnostics, not authorization
	LoopGeneration        uint64
}

type resumeChallenge struct {
	ProviderID, NodeKey, SeKey, Token string
	ExpiresAt                         time.Time
	Done                              chan struct{}
}
