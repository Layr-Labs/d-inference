package testbed

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/google/uuid"
)

type Instrument struct {
	consumer EventConsumer
	mu       sync.Mutex
}

func NewInstrument(consumer EventConsumer) *Instrument {
	return &Instrument{consumer: consumer}
}

func (inst *Instrument) emit(event Event) {
	inst.mu.Lock()
	defer inst.mu.Unlock()
	inst.consumer.Consume(event)
}

func newEvent(kind EventKind, requestID string, segment Segment) Event {
	return Event{
		SchemaVersion: SchemaVersion,
		Kind:          kind,
		RequestID:     requestID,
		Segment:       segment,
		Timestamp:     time.Now(),
	}
}

func (inst *Instrument) NewRequestID() string {
	return uuid.New().String()
}

func (inst *Instrument) RequestStart(requestID string) {
	inst.emit(newEvent(EventRequestStart, requestID, ""))
}

func (inst *Instrument) RequestEnd(requestID string, duration time.Duration) {
	e := newEvent(EventRequestEnd, requestID, "")
	e.Duration = duration
	inst.emit(e)
}

type SegmentTimer struct {
	inst      *Instrument
	requestID string
	segment   Segment
	start     time.Time
}

func (inst *Instrument) StartSegment(requestID string, segment Segment) *SegmentTimer {
	st := &SegmentTimer{
		inst:      inst,
		requestID: requestID,
		segment:   segment,
		start:     time.Now(),
	}
	inst.emit(newEvent(EventSegmentStart, requestID, segment))
	return st
}

func (st *SegmentTimer) Stop() {
	duration := time.Since(st.start)
	e := newEvent(EventSegmentEnd, st.requestID, st.segment)
	e.Duration = duration
	e.Timestamp = time.Now()
	st.inst.emit(e)
}

func (inst *Instrument) StreamChunk(requestID string, chunkIndex int) {
	e := newEvent(EventStreamChunk, requestID, "")
	meta, _ := json.Marshal(map[string]int{"chunk_index": chunkIndex})
	e.Metadata = meta
	inst.emit(e)
}

func (inst *Instrument) Error(requestID string, err error) {
	e := newEvent(EventError, requestID, "")
	meta, _ := json.Marshal(map[string]string{"error": err.Error()})
	e.Metadata = meta
	inst.emit(e)
}

type RequestInstrument struct {
	inst      *Instrument
	RequestID string
}

func (inst *Instrument) NewRequest() *RequestInstrument {
	rid := inst.NewRequestID()
	inst.RequestStart(rid)
	return &RequestInstrument{inst: inst, RequestID: rid}
}

func (ri *RequestInstrument) StartSegment(segment Segment) *SegmentTimer {
	return ri.inst.StartSegment(ri.RequestID, segment)
}

func (ri *RequestInstrument) StreamChunk(chunkIndex int) {
	ri.inst.StreamChunk(ri.RequestID, chunkIndex)
}

func (ri *RequestInstrument) Error(err error) {
	ri.inst.Error(ri.RequestID, err)
}

func (ri *RequestInstrument) End() {
	ri.inst.RequestEnd(ri.RequestID, 0)
}

func (ri *RequestInstrument) EndWithDuration(d time.Duration) {
	ri.inst.RequestEnd(ri.RequestID, d)
}
