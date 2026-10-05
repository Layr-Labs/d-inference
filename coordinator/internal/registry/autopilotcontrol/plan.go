// Package autopilotcontrol owns the bounded placement pass and its live
// reservation protocol. Session identities are opaque to placement policy.
package autopilotcontrol

import (
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/google/uuid"
)

type Fleet[T comparable] struct {
	autopilot.Fleet
	sessions map[string]T
}

func NewFleet[T comparable](demand map[string]autopilot.DemandView) Fleet[T] {
	return Fleet[T]{Fleet: autopilot.Fleet{Demand: demand, Floors: map[string]int{}, Excluded: map[string]int{}}, sessions: map[string]T{}}
}

func (f *Fleet[T]) Add(node autopilot.Node, session T) {
	f.Nodes = append(f.Nodes, node)
	f.sessions[node.ID] = session
}

func (f *Fleet[T]) Order() {
	slices.SortFunc(f.Nodes, func(a, b autopilot.Node) int {
		if a.ID < b.ID {
			return -1
		}
		if a.ID > b.ID {
			return 1
		}
		return 0
	})
}

type Action[T comparable] struct {
	autopilot.Action
	Session T
}

func Plan[T comparable](f Fleet[T], cfg autopilot.Config, now time.Time) *Action[T] {
	action := autopilot.Plan(f.Fleet, cfg, now)
	if action == nil {
		return nil
	}
	session, ok := f.sessions[action.Node.ID]
	if !ok {
		return nil
	}
	return &Action[T]{Action: *action, Session: session}
}

// Reservation holds the registry's exclusive placement lease. Commit performs
// the final provider-local authority check before installing command ownership.
type Reservation[T comparable] struct {
	Fleet   Fleet[T]
	Commit  func(Action[T], protocol.ModelAutopilotMessage, time.Time) bool
	Release func()
}

func (c *Controller[T]) Reserve(a Action[T], now time.Time) (protocol.ModelAutopilotMessage, bool) {
	lease, ok := c.ports.BeginReservation(now)
	if !ok {
		return protocol.ModelAutopilotMessage{}, false
	}
	defer lease.Release()
	f := lease.Fleet
	active := f.LegacyPending
	for _, n := range f.Nodes {
		if n.Pending {
			active++
		}
	}
	if active >= c.config.MaxConcurrentOperations {
		return protocol.ModelAutopilotMessage{}, false
	}
	var node *autopilot.Node
	for i := range f.Nodes {
		if f.Nodes[i].ID == a.Node.ID {
			node = &f.Nodes[i]
			break
		}
	}
	if node == nil || f.sessions[node.ID] != a.Session || node.Seq != a.Node.Seq || !node.Managed || !node.Idle || node.Pending || !slices.Equal(autopilot.ResidentIDs(node.State), autopilot.ResidentIDs(a.Node.State)) {
		return protocol.ModelAutopilotMessage{}, false
	}
	// Keep every donor's current coverage, but only replan this recipient.
	for i := range f.Nodes {
		if f.Nodes[i].ID != a.Node.ID {
			f.Nodes[i].Idle = false
		}
	}
	fresh := Plan(f, c.config, now)
	if fresh == nil || fresh.Load != a.Load || !slices.Equal(autopilot.SortedStrings(fresh.Unload), autopilot.SortedStrings(a.Unload)) {
		return protocol.ModelAutopilotMessage{}, false
	}
	cmd := protocol.ModelAutopilotMessage{Reason: fresh.Reason, Type: protocol.TypeModelAutopilot, SessionID: node.ID, Revision: node.State.Revision, CommandID: uuid.NewString(), LoadModelID: fresh.Load, UnloadModelIDs: append([]string{}, fresh.Unload...), ExpectedResidentModels: autopilot.ResidentIDs(node.State), ExpiresAtMS: now.Add(c.config.CommandAcceptTimeout).UnixMilli(), LeaseSeconds: int(c.config.MinDwell.Seconds())}
	if !lease.Commit(*fresh, cmd, now) {
		return protocol.ModelAutopilotMessage{}, false
	}
	return cmd, true
}
