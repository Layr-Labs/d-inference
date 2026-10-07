// Package cacheattempt owns immutable receipt metadata and the queue-dequeue
// cutoff for one provider attempt. It never reads a replacement request owner.
package cacheattempt

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"sync/atomic"
)

type Gate interface{ Active() bool }

// Retention is the receipt store belonging to the captured tracker generation.
// Terminal shortens receipt grace using that store's retained clock.
type Retention interface {
	Forget(string)
	Terminal(string)
}

type Metadata struct {
	Nonce                string
	Scope                string
	BoundaryMode         string
	RepeatedPrefixTokens int
}

type Owner struct {
	metadata  Metadata
	gate      Gate
	retention Retention
	revoked   atomic.Bool
	dispatch  atomic.Uint32
}

const (
	prepared uint32 = iota
	accepted
	cold
)

func New(metadata Metadata, gate Gate, retention Retention) *Owner {
	return &Owner{metadata: metadata, gate: gate, retention: retention}
}

func (o *Owner) Revoke()            { o.revoked.Store(true) }
func (o *Owner) Participates() bool { return o != nil && o.dispatch.Load() != cold }

func (o *Owner) ForgetReceipt() {
	if o.retention != nil {
		o.retention.Forget(o.metadata.Nonce)
	}
}

func (o *Owner) TerminalReceipt() {
	if o.retention != nil {
		o.retention.Terminal(o.metadata.Nonce)
	}
}

// Snapshot captures immutable metadata for one queued frame, never a replacement
// preparation's owner. Its zero value encodes an ordinary uncached request.
type Snapshot struct{ owner *Owner }

func (s Snapshot) ApplyTo(message *protocol.InferenceRequestMessage) {
	s.owner.ApplyTo(message)
}

// MetadataMessage encodes a fresh wire value without accepting a dequeue.
func (s Snapshot) MetadataMessage() protocol.InferenceRequestMessage {
	o := s.owner
	if o == nil {
		return protocol.InferenceRequestMessage{}
	}
	repeated := o.metadata.RepeatedPrefixTokens
	return protocol.InferenceRequestMessage{
		CacheReceiptNonce: o.metadata.Nonce, CacheScope: o.metadata.Scope,
		PrefixCacheProtocol: 2, CacheReceiptBoundaryMode: o.metadata.BoundaryMode,
		CacheRepeatedPrefixTokens: &repeated,
	}
}

// ApplyTo accepts only this immutable owner, after revocation checks at writer
// dequeue. Revocation after acceptance cannot retract an already encoded frame.
func (o *Owner) ApplyTo(message *protocol.InferenceRequestMessage) {
	message.CacheReceiptNonce, message.CacheScope = "", ""
	message.PrefixCacheProtocol, message.CacheReceiptBoundaryMode = 0, ""
	message.CacheRepeatedPrefixTokens = nil
	if o == nil {
		return
	}
	if o.revoked.Load() || o.gate == nil || !o.gate.Active() {
		o.dispatch.CompareAndSwap(prepared, cold)
		return
	}
	o.dispatch.Store(accepted)
	wire := (Snapshot{owner: o}).MetadataMessage()
	message.CacheReceiptNonce, message.CacheScope = wire.CacheReceiptNonce, wire.CacheScope
	message.PrefixCacheProtocol, message.CacheReceiptBoundaryMode = wire.PrefixCacheProtocol, wire.CacheReceiptBoundaryMode
	message.CacheRepeatedPrefixTokens = wire.CacheRepeatedPrefixTokens
}
