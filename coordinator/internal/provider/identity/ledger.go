package identity

import (
	"crypto/sha256"
	"sync"
	"sync/atomic"
	"time"
)

// The same lock protects push admission, proof reuse and resume consumption.
type ledger struct {
	mu                     sync.Mutex
	publicationGeneration  uint64
	forgotten              map[[sha256.Size]byte]uint64
	attested               map[string]proofRecord
	lastPush               map[string]time.Time
	lastBudgetClear        map[string]time.Time
	outstanding            map[string][]pushChallenge
	resumeChallenges       map[string]resumeChallenge
	loopGeneration         atomic.Uint64
	loopGenerations        map[string]uint64
	loopTokens             map[string]string
	durableNextPush        map[string]time.Time
	novelTokenBlockedUntil map[string]time.Time
	novelPushFloor         map[string]time.Time
	budgetTokenOrder       map[string][]string
	reservationLocks       map[string]*reservationLock
}

type reservationLock struct {
	mu    sync.Mutex
	users int
}

func newLedger() *ledger {
	return &ledger{
		forgotten:              make(map[[sha256.Size]byte]uint64),
		attested:               make(map[string]proofRecord),
		lastPush:               make(map[string]time.Time),
		lastBudgetClear:        make(map[string]time.Time),
		outstanding:            make(map[string][]pushChallenge),
		resumeChallenges:       make(map[string]resumeChallenge),
		loopGenerations:        make(map[string]uint64),
		loopTokens:             make(map[string]string),
		durableNextPush:        make(map[string]time.Time),
		novelTokenBlockedUntil: make(map[string]time.Time),
		novelPushFloor:         make(map[string]time.Time),
		budgetTokenOrder:       make(map[string][]string),
		reservationLocks:       make(map[string]*reservationLock),
	}
}
