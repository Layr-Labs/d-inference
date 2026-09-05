package api

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/outcomes"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type accountingBlockingStore struct {
	store.Store
	started    chan struct{}
	release    chan struct{}
	calls      atomic.Int64
	panicFirst bool
}

func (s *accountingBlockingStore) RecordRequestOutcomes(rows []*outcomes.Record) error {
	if s.calls.Add(1) == 1 {
		close(s.started)
		if s.panicFirst {
			panic("test accounting sink failure")
		}
		<-s.release
	}
	return s.Store.RecordRequestOutcomes(rows)
}

func TestRequestAccountingSinkBoundedDuringStoreStall(t *testing.T) {
	st := &accountingBlockingStore{Store: store.NewMemory(store.Config{}), started: make(chan struct{}), release: make(chan struct{})}
	srv := &Server{store: st}
	sink := newRequestOutcomeSink(srv, 1)
	tracker := outcomes.New("one", "/v1/messages", time.Now(), sink.submit)
	select {
	case <-st.started:
	case <-time.After(time.Second):
		t.Fatal("sink did not write")
	}
	tracker.Finish(401, false, false)
	for i := 0; i < 20; i++ {
		sink.submit(&outcomes.Record{})
	}
	if sink.dropped.Load() != 20 || len(sink.ch) != 1 {
		t.Fatalf("sink pressure: dropped=%d queued=%d", sink.dropped.Load(), len(sink.ch))
	}
	close(st.release)
	sink.close()
	rows, err := st.RequestOutcomesBetween(context.Background(), time.Time{}, time.Now(), 10)
	if err != nil || len(rows) != 1 || rows[0].Termination != "rejected" {
		t.Fatalf("terminal drain: %+v %v", rows, err)
	}
	sink.submit(&outcomes.Record{})
	if sink.dropped.Load() != 21 {
		t.Fatal("closed sink accepted a snapshot")
	}
}

func TestRequestAccountingSinkSurvivesStorePanicAndRescuesMissingReceipt(t *testing.T) {
	st := &accountingBlockingStore{Store: store.NewMemory(store.Config{}), started: make(chan struct{}), panicFirst: true}
	sink := newRequestOutcomeSink(&Server{store: st}, 4)
	tracker := outcomes.New("rescued", "/v1/messages", time.Now(), sink.submit)
	select {
	case <-st.started:
	case <-time.After(time.Second):
		t.Fatal("sink did not write")
	}
	tracker.Finish(429, false, false)
	sink.close()
	rows, err := st.RequestOutcomesBetween(context.Background(), time.Time{}, time.Now(), 10)
	if err != nil || len(rows) != 1 || rows[0].Revision != 2 || rows[0].Termination != "rejected" {
		t.Fatalf("terminal snapshot did not rescue lost receipt: %+v %v", rows, err)
	}
	if sink.dropped.Load() != 1 {
		t.Fatalf("lost receipt not counted: %d", sink.dropped.Load())
	}
}
