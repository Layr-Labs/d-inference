package registry

import (
	"bytes"
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Reuse the actual Registry/WS fixture. These opaque records establish relay
// behavior only; no synthetic payload is represented as a native Ready proof.
func workerBoundaryReady(t *testing.T, f *nativePairFixture, s *NativePairSession, d [32]byte, payload []byte) {
	t.Helper()
	for rank := range f.n {
		p := workerFixturePacket(1, d, 0, payload)
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairWorkerReady, p)); e != nil {
			t.Fatal(e)
		}
	}
	f.read(t, 0, protocol.TypeNativePairWorkerReady)
}

func workerBoundaryStopped(t *testing.T, f *nativePairFixture, s *NativePairSession) [2]protocol.NativePairMessage {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if e := s.WaitControlStopped(ctx); e != nil {
		t.Fatal("relay workers did not join", e)
	}
	var canceled [2]protocol.NativePairMessage
	for rank := range f.n {
		canceled[rank] = f.read(t, rank, protocol.TypeNativePairCancel)
	}
	return canceled
}

func workerBoundaryReleased(t *testing.T, f *nativePairFixture, s *NativePairSession) {
	t.Helper()
	for rank := range f.n {
		if e := f.c.Handle(f.n[rank], f.signed(t, s, rank, protocol.TypeNativePairOwnerReleased, nativePairReleaseReceipt(s.starts[rank]))); e != nil {
			t.Fatal("original owner release refused", e)
		}
	}
}

func workerBoundaryPublicationDone(t *testing.T, f *nativePairFixture, s *NativePairSession) {
	t.Helper()
	f.c.mu.Lock()
	done := s.workerReleaseDone
	f.c.mu.Unlock()
	if done == nil {
		t.Fatal("aggregate publication never started")
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("aggregate publication did not complete its enqueue/close attempts")
	}
}

func TestNativePairWorkerExactlyOneReadyNeverAdmitsCommand(t *testing.T) {
	for _, onlyRank := range []int{0, 1} {
		t.Run(string(rune('0'+onlyRank)), func(t *testing.T) {
			f, s, d := protectedWorkerFixture(t, true)
			p := workerFixturePacket(1, d, 0, []byte("one-ready"))
			if e := f.c.Handle(f.n[onlyRank], f.signed(t, s, onlyRank, protocol.TypeNativePairWorkerReady, p)); e != nil {
				t.Fatal(e)
			}
			for _, ch := range f.frames {
				select {
				case <-ch:
					t.Fatal("one Ready produced a peer Ready")
				default:
				}
			}
			p = workerFixturePacket(2, d, 0, []byte("command"))
			if e := f.c.Handle(f.n[0], f.signed(t, s, 0, protocol.TypeNativePairWorkerCommand, p)); e == nil {
				t.Fatal("one Ready admitted request work")
			}
			workerBoundaryStopped(t, f, s)
			if f.phase(s) != VerifiedPairQuarantined {
				t.Fatal("one Ready rejection freed original owners")
			}
		})
	}
}

func TestNativePairWorkerLateFramesCannotEscapeStopOrOneRelease(t *testing.T) {
	for _, reason := range []string{"cancel", "one-original-release"} {
		t.Run(reason, func(t *testing.T) {
			f, s, d := protectedWorkerFixture(t, true)
			workerBoundaryReady(t, f, s, d, []byte("ready"))
			if reason == "cancel" {
				f.c.Cancel(s)
			} else if e := f.c.Handle(f.n[0], f.signed(t, s, 0, protocol.TypeNativePairOwnerReleased, nativePairReleaseReceipt(s.starts[0]))); e != nil {
				t.Fatal(e)
			}
			workerBoundaryStopped(t, f, s)
			f.c.mu.Lock()
			beforeRecords, beforeBytes := s.workerRecords, s.workerBytes
			f.c.mu.Unlock()
			for _, frame := range []struct {
				rank int
				kind string
				tag  byte
			}{
				{1, protocol.TypeNativePairWorkerEvent, 3},
				{0, protocol.TypeNativePairWorkerCommand, 2},
				{1, protocol.TypeNativePairWorkerReady, 1},
			} {
				p := workerFixturePacket(frame.tag, d, 0, []byte("late"))
				if e := f.c.Handle(f.n[frame.rank], f.signed(t, s, frame.rank, frame.kind, p)); e == nil {
					t.Fatal("late worker frame accepted", frame.kind)
				}
			}
			f.c.mu.Lock()
			unchanged := s.workerRecords == beforeRecords && s.workerBytes == beforeBytes && !s.workerReleaseStarted
			f.c.mu.Unlock()
			if !unchanged || f.phase(s) != VerifiedPairQuarantined {
				t.Fatal("late frame changed request counters or owner hold")
			}
			for _, ch := range f.frames {
				select {
				case <-ch:
					t.Fatal("late frame/aggregate escaped the stopped relay")
				default:
				}
			}
			if _, e := f.c.Reserve(f.n, f.policy.ID, time.Minute); e == nil {
				t.Fatal("late work or one release enabled replacement")
			}
		})
	}
}

func TestNativePairWorkerAggregatePublicationMustPrecedeReplacement(t *testing.T) {
	f, s, _ := protectedWorkerFixture(t, false)
	f.c.Cancel(s)
	canceled := workerBoundaryStopped(t, f, s)
	f.p[0].mu.Lock()
	w := f.p[0].writer
	f.p[0].mu.Unlock()
	if w == nil {
		t.Fatal("actual writer absent")
	}
	// Block the existing enqueue lock, not a mocked callback or a scheduler
	// sleep. The real aggregate goroutine cannot finish rank0 publication.
	w.acceptMu.Lock()
	locked := true
	defer func() {
		if locked {
			w.acceptMu.Unlock()
		}
	}()
	workerBoundaryReleased(t, f, s)
	f.c.mu.Lock()
	held := s.workerReleaseStarted && !s.workerReleasePublished && s.writersEnded && s.cancellationPublished && f.c.sessions[s.membership.Epoch] == s
	for _, n := range f.n {
		held = held && n.session == s
	}
	f.c.mu.Unlock()
	if !held || f.phase(s) != VerifiedPairReleased {
		t.Fatal("publication gap lost its exact attachment obligation")
	}
	if _, e := f.c.Reserve(f.n, f.policy.ID, time.Minute); e == nil {
		t.Fatal("replacement overtook aggregate publication")
	}
	for _, ch := range f.frames {
		select {
		case <-ch:
			t.Fatal("aggregate escaped the held enqueue lock")
		default:
		}
	}
	w.acceptMu.Unlock()
	locked = false
	workerBoundaryPublicationDone(t, f, s)
	next, e := f.c.Reserve(f.n, f.policy.ID, time.Minute)
	if e != nil {
		t.Fatal("replacement refused after publication", e)
	}
	// Reserve before reading sockets: exercise actual priority FIFO ordering.
	for rank := range f.n {
		released := f.read(t, rank, protocol.TypeNativePairWorkersReleased)
		prepared := f.read(t, rank, protocol.TypeNativePairPrepare)
		payload, _ := released.PayloadBytes()
		if !bytes.Equal(payload, nativePairWorkersReleased(s.starts)) || released.Epoch != canceled[rank].Epoch || prepared.Epoch == released.Epoch ||
			!(canceled[rank].Sequence < released.Sequence && released.Sequence < prepared.Sequence) {
			t.Fatal("old cancel/aggregate/new prepare wire order or original Start binding differs")
		}
	}
	f.c.Cancel(s)
	if f.phase(next) != VerifiedPairPending {
		t.Fatal("old cancellation affected replacement")
	}
}

func TestNativePairWorkerAggregateEnqueueFailureClosesOriginalConnection(t *testing.T) {
	for _, failedRank := range []int{0, 1} {
		t.Run(string(rune('0'+failedRank)), func(t *testing.T) {
			f, s, _ := protectedWorkerFixture(t, false)
			f.c.Cancel(s)
			workerBoundaryStopped(t, f, s)
			// Real writer failure, with the Registry's original signed owner
			// receipts kept separate. Do not inject a successful publication.
			f.p[failedRank].closeWriterNow()
			workerBoundaryReleased(t, f, s)
			workerBoundaryPublicationDone(t, f, s)
			f.c.mu.Lock()
			failedClosed := f.n[failedRank].closed && s.workerReleasePublished && f.c.sessions[s.membership.Epoch] == nil
			f.c.mu.Unlock()
			if !failedClosed || f.phase(s) != VerifiedPairReleased {
				t.Fatal("failed aggregate did not close the original control connection")
			}
			m := f.read(t, 1-failedRank, protocol.TypeNativePairWorkersReleased)
			p, _ := m.PayloadBytes()
			if !bytes.Equal(p, nativePairWorkersReleased(s.starts)) {
				t.Fatal("healthy peer aggregate differs")
			}
			select {
			case <-f.frames[failedRank]:
				t.Fatal("failed peer received aggregate")
			default:
			}
			if _, e := f.c.Reserve(f.n, f.policy.ID, time.Minute); e == nil {
				t.Fatal("failed publication permitted reuse of closed connection")
			}
		})
	}
}

func TestNativePairWorkerRecordAndByteBudgetsUseActualFrames(t *testing.T) {
	for _, mode := range []string{"records", "exact-bytes", "over-bytes"} {
		t.Run(mode, func(t *testing.T) {
			f, s, d := protectedWorkerFixture(t, true)
			payload := []byte("x")
			if mode != "records" {
				payload = bytes.Repeat([]byte{7}, protocol.NativePairWorkerPayloadLimit)
			}
			workerBoundaryReady(t, f, s, d, payload)
			event := workerFixturePacket(3, d, 0, payload)
			// One actual Ready plus 126 actual events: no direct counter edits.
			for i := 0; i < 126; i++ {
				if e := f.c.Handle(f.n[1], f.signed(t, s, 1, protocol.TypeNativePairWorkerEvent, event)); e != nil {
					t.Fatal(i, e)
				}
				f.read(t, 0, protocol.TypeNativePairWorkerEvent)
			}
			f.c.mu.Lock()
			count, used := s.workerRecords[1], s.workerBytes[1]
			f.c.mu.Unlock()
			if count != 127 || used != 127*uint64(len(event)) {
				t.Fatal("actual frame counters differ")
			}
			if mode != "records" {
				remaining := 2*1024*1024 - int(used)
				length := remaining - 58
				if mode == "over-bytes" {
					length++
				}
				if length < 1 || length > protocol.NativePairWorkerPayloadLimit {
					t.Fatal("invalid boundary fixture")
				}
				event = workerFixturePacket(3, d, 0, bytes.Repeat([]byte{8}, length))
			}
			e := f.c.Handle(f.n[1], f.signed(t, s, 1, protocol.TypeNativePairWorkerEvent, event))
			if mode == "over-bytes" {
				if e == nil {
					t.Fatal("one byte over cumulative budget admitted below record cap")
				}
				workerBoundaryStopped(t, f, s)
				f.c.mu.Lock()
				unchanged := s.workerRecords[1] == count && s.workerBytes[1] == used
				f.c.mu.Unlock()
				if !unchanged || f.phase(s) != VerifiedPairQuarantined {
					t.Fatal("byte refusal changed counters or freed owners")
				}
				return
			}
			if e != nil {
				t.Fatal("exact boundary refused", e)
			}
			f.read(t, 0, protocol.TypeNativePairWorkerEvent)
			f.c.mu.Lock()
			count, used = s.workerRecords[1], s.workerBytes[1]
			f.c.mu.Unlock()
			if count != 128 || (mode == "exact-bytes" && used != 2*1024*1024) || f.phase(s) != VerifiedPairActive {
				t.Fatal("exact budget did not remain admitted")
			}
			if mode == "records" {
				if used+uint64(len(event)) >= 2*1024*1024 {
					t.Fatal("record fixture also hits byte cap")
				}
				if e = f.c.Handle(f.n[1], f.signed(t, s, 1, protocol.TypeNativePairWorkerEvent, event)); e == nil {
					t.Fatal("129th record admitted")
				}
				workerBoundaryStopped(t, f, s)
				if f.phase(s) != VerifiedPairQuarantined {
					t.Fatal("record exhaustion released owners")
				}
			}
		})
	}
}
