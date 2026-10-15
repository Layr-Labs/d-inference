package protocol

import (
	"bytes"
	"encoding/binary"
)

// Closed transport record, never a native key or executable invocation. The
// member is responsible for strict worker codec/identity/state validation.
const NativePairWorkerPayloadLimit = 16 * 1024

func IsNativePairWorker(kind string) bool {
	switch kind {
	case TypeNativePairWorkerReady, TypeNativePairWorkerCommand, TypeNativePairWorkerEvent, TypeNativePairWorkerAttach:
		return true
	}
	return false
}

type NativePairWorkerPacket struct {
	Kind                           byte
	DeliverySlack, GenerationSlack uint64
	Payload                        []byte
}

func DecodeNativePairWorkerPacket(b []byte, kind string, transcript [32]byte) (NativePairWorkerPacket, error) {
	var p NativePairWorkerPacket
	if transcript == [32]byte{} || len(b) < 59 || len(b) > 58+NativePairWorkerPayloadLimit || !bytes.Equal(b[:5], []byte("DBNW\x01")) || !bytes.Equal(b[6:38], transcript[:]) {
		return p, ErrNativePairFrame
	}
	expected := byte(0)
	switch kind {
	case TypeNativePairWorkerReady:
		expected = 1
	case TypeNativePairWorkerCommand:
		expected = 2
	case TypeNativePairWorkerEvent:
		expected = 3
	}
	if expected == 0 || b[5] != expected || binary.BigEndian.Uint32(b[54:58]) != uint32(len(b)-58) {
		return p, ErrNativePairFrame
	}
	p.Kind = expected
	p.DeliverySlack = binary.BigEndian.Uint64(b[38:46])
	p.GenerationSlack = binary.BigEndian.Uint64(b[46:54])
	p.Payload = append([]byte(nil), b[58:]...)
	if p.DeliverySlack > 3600000000000 || p.GenerationSlack > 3600000000000 || (expected != 2 && (p.DeliverySlack != 0 || p.GenerationSlack != 0)) {
		return NativePairWorkerPacket{}, ErrNativePairFrame
	}
	return p, nil
}
