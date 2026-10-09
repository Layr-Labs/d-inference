package provider_test

// A control-only member publishes its cluster inventory, and the coordinator
// used to compute alias convergence from it like an ordinary inventory: a
// member whose cluster model was an alias's previous build was told to fetch
// the desired build. These tests drive real provider sessions and assert that
// a member is sent no model work, while catalog publication, which reports
// failure when any provider's desired_models is undeliverable, still succeeds
// with a member connected.

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const nextAliasBuild = "cluster-member-fixture-next-build"

// publishAliasOverFixtureModel makes the fixture model the previous build of a
// public alias, so an ordinary advertiser is told to converge to the next one.
func publishAliasOverFixtureModel(reg *registry.Registry) {
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: clusterMemberFixtureModel}, {ID: nextAliasBuild}})
	reg.SetModelAliases(map[string]registry.AliasTarget{
		"public-alias": {Desired: nextAliasBuild, Previous: clusterMemberFixtureModel},
	})
}

func desiredModelFrames(t *testing.T, frames [][]byte) []protocol.DesiredModelsMessage {
	t.Helper()
	var found []protocol.DesiredModelsMessage
	for _, frame := range frames {
		if frameType(t, frame) != protocol.TypeDesiredModels {
			continue
		}
		var message protocol.DesiredModelsMessage
		if err := json.Unmarshal(frame, &message); err != nil {
			t.Fatalf("desired_models frame: %v", err)
		}
		found = append(found, message)
	}
	return found
}

func TestClusterMemberSessionIsSentNoModelWork(t *testing.T) {
	// Control: the same catalog tells an ordinary advertiser of the previous
	// build to converge, so the member assertions below are not vacuous.
	t.Run("solo control converges", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		session := dialProviderSession(t, ctx, nil, false)
		publishAliasOverFixtureModel(session.registry)
		writeProviderFrame(t, ctx, session.conn, soloRegistration())

		desired := desiredModelFrames(t, framesThroughDrainBarrier(t, ctx, session.conn))
		if len(desired) != 1 || len(desired[0].Models) != 1 || desired[0].Models[0].DesiredBuild != nextAliasBuild {
			t.Fatalf("ordinary advertiser was not told to converge: %+v", desired)
		}
	})

	t.Run("member", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		session := dialProviderSession(t, ctx, nil, false)
		publishAliasOverFixtureModel(session.registry)
		writeProviderFrame(t, ctx, session.conn, memberRegistration(strings.Repeat("0123456789abcdef", 4)))
		frames := readFramesThrough(t, ctx, session.conn, protocol.TypeClusterMemberAccepted)

		// Model commands are written synchronously, so everything publication
		// sends is on the wire before the drain barrier's acknowledgement.
		if !session.owner.catalog.FanOutDesiredModels() {
			t.Fatal("catalog publication reported a delivery failure with a member connected")
		}
		frames = append(frames, framesThroughDrainBarrier(t, ctx, session.conn)...)

		desired := desiredModelFrames(t, frames)
		if len(desired) == 0 {
			t.Fatal("member was not sent the empty desired_models revoke at registration")
		}
		for _, message := range desired {
			if len(message.Models) != 0 {
				t.Fatalf("member was sent model work: %+v", message.Models)
			}
		}
		for _, frame := range frames {
			switch frameType(t, frame) {
			case protocol.TypeLoadModel, protocol.TypePrefetchModel:
				t.Fatalf("member was sent a model command: %s", frame)
			}
		}
	})
}
