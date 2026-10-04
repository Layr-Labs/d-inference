package service

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/exchange"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/transcript"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (x *Session) verificationDependencies() exchange.Dependencies {
	return exchange.Dependencies{
		Keys: x.store, Verifier: x.verifier, OwnerMatches: x.keyOwnerMatches,
		Rotate: func(ctx context.Context, key *store.AppAttestShadowKey) bool {
			x.key, x.owner = key, key.Owner
			return x.maybeRequestKeyRotation(ctx, key)
		},
		Observe: x.observeWithClientDiagnostics, ReceiptNow: x.s.receiptNow, MachineID: x.machineID,
	}
}

func (x *Session) issuedChallenge() exchange.Challenge {
	return exchange.Challenge{Binding: transcript.Binding{
		Session: x.id, Challenge: x.challenge, PublicKey: x.publicKey, Owner: x.owner, Account: x.account,
		AppID: x.s.config.AppID, Environment: x.s.config.Environment, ProtocolVersion: x.protocolVersion,
	}, Expected: x.expected, Started: x.started, Credential: x.key}
}

func (x *Session) applyExchangeResult(result exchange.Result, reply protocol.AppAttestShadowPayload) {
	if result.ReadyObserved {
		x.readyDiagnostics = result.ReadyContext
	}
	if result.Credential != nil {
		x.key = result.Credential
	}
	if result.Owner != "" {
		x.owner = result.Owner
	}
	if !result.AssertionAt.IsZero() {
		x.assertionAt = result.AssertionAt
		x.observeBuildPolicy(reply.Status, result.AssertionMetadata)
	}
}
