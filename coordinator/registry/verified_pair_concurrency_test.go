package registry

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestVerifiedPairConcurrentOverlappingReservations(t *testing.T) {
	r, members, request := pairTestRegistry(t)
	third := pairTestMember(t, r, "pair-c", "serial-c")
	start := make(chan struct{})
	var wg sync.WaitGroup
	var handles [2]*VerifiedPairHandle
	var errs [2]error
	pairs := [2][2]*Provider{members, {third, members[0]}}
	for i := range pairs {
		wg.Add(1)
		go func(index int) {
			defer wg.Done()
			<-start
			handles[index], _, errs[index] = r.ReserveVerifiedPair(pairs[index], request)
		}(i)
	}
	close(start)
	wg.Wait()
	winners := 0
	for i, h := range handles {
		if h != nil {
			winners++
		} else if !errors.Is(errs[i], ErrVerifiedPairBusy) {
			t.Fatalf("unexpected refusal %v", errs[i])
		}
	}
	if winners != 1 {
		t.Fatalf("overlapping pair winners=%d", winners)
	}
	r.mu.RLock()
	states, connections, devices := len(r.verifiedPairs.states), len(r.verifiedPairs.connections), len(r.verifiedPairs.devices)
	r.mu.RUnlock()
	if states != 1 || connections != 2 || devices != 4 {
		t.Fatal("partial or double device reservation")
	}
}

func TestVerifiedPairAndActualSoloCommitCannotBothWin(t *testing.T) {
	for iteration := 0; iteration < 12; iteration++ {
		r, members, request := pairTestRegistry(t)
		start := make(chan struct{})
		var wg sync.WaitGroup
		var h *VerifiedPairHandle
		var pairErr error
		var solo *Provider
		pr := &PendingRequest{RequestID: "competing-solo", Model: pairTestModel, RequestedMaxTokens: 1}
		wg.Add(2)
		go func() { defer wg.Done(); <-start; h, _, pairErr = r.ReserveVerifiedPair(members, request) }()
		go func() { defer wg.Done(); <-start; solo, _ = r.ReserveProviderEx(pairTestModel, pr) }()
		close(start)
		wg.Wait()
		if (h != nil) == (solo != nil) {
			t.Fatalf("pair=%v solo=%v; expected exactly one commit", h != nil, solo != nil)
		}
		if h == nil && !errors.Is(pairErr, ErrVerifiedPairBusy) {
			t.Fatalf("unexpected pair failure: %v", pairErr)
		}
		if solo != nil {
			solo.RemovePending(pr.RequestID)
		}
		if h != nil {
			if err := r.CancelVerifiedPair(h); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func TestVerifiedPairSeesModelCommandAlreadyBeingWritten(t *testing.T) {
	r, members, request := pairTestRegistry(t)
	entered, finish, result := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	r.loadModelSender = func(_, _ string) error { close(entered); <-finish; return nil }
	go func() { result <- r.SendLoadModel(members[0].ID, pairTestModel) }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("model command did not enter")
	}
	if _, _, err := r.ReserveVerifiedPair(members, request); !errors.Is(err, ErrVerifiedPairBusy) {
		close(finish)
		<-result
		t.Fatal("pair crossed model command write")
	}
	close(finish)
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	pairTestReserve(t, r, members, request)
}

func TestVerifiedPairRefusesDuplicatePhysicalConnectionAndBusyViews(t *testing.T) {
	t.Run("duplicate", func(t *testing.T) {
		r, members, request := pairTestRegistry(t)
		pairTestMember(t, r, "alias", "serial-a")
		if _, _, err := r.ReserveVerifiedPair(members, request); !errors.Is(err, ErrVerifiedPairBusy) {
			t.Fatal("ignored alias on selected physical device")
		}
	})
	t.Run("same_device", func(t *testing.T) {
		r, members, request := pairTestRegistry(t)
		alias := pairTestMember(t, r, "alias", "serial-a")
		if _, _, err := r.ReserveVerifiedPair([2]*Provider{members[0], alias}, request); !errors.Is(err, ErrVerifiedPairInput) {
			t.Fatal("same physical device selected twice")
		}
	})
	for _, view := range []string{"pending_request", "pending_load", "running", "waiting", "reloading"} {
		t.Run(view, func(t *testing.T) {
			r, members, request := pairTestRegistry(t)
			p := members[1]
			r.mu.Lock()
			p.mu.Lock()
			switch view {
			case "pending_request":
				p.addPendingLocked(&PendingRequest{RequestID: "already-admitted"})
			case "pending_load":
				r.pendingModelLoads = map[modelLoadKey]time.Time{{ProviderID: p.ID, ModelID: pairTestModel}: time.Now().Add(time.Minute)}
			case "running":
				p.BackendCapacity.Slots[0].NumRunning = 1
			case "waiting":
				p.BackendCapacity.Slots[0].NumWaiting = 1
			case "reloading":
				p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{Model: pairTestModel, State: "reloading"}}
			}
			p.mu.Unlock()
			r.mu.Unlock()
			if _, _, err := r.ReserveVerifiedPair(members, request); !errors.Is(err, ErrVerifiedPairBusy) {
				t.Fatalf("ignored busy %s: %v", view, err)
			}
		})
	}
}

func TestVerifiedPairModelLoadCommitRechecksHold(t *testing.T) {
	r, members, request := pairTestRegistry(t)
	// This action was planned before the pair committed its pending hold.
	actions := []modelLoadAction{{providerID: members[0].ID, modelID: pairTestModel}}
	pairTestReserve(t, r, members, request)
	if got := r.reservePendingModelLoads(actions, time.Now()); len(got) != 0 {
		t.Fatal("old load plan committed over pair hold")
	}
}
