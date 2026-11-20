package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func workerBoundaryPacket(tag byte, transcript [32]byte, payload []byte) []byte {
	b := append([]byte{'D', 'B', 'N', 'W', 1, tag}, transcript[:]...)
	b = binary.BigEndian.AppendUint64(b, 0)
	b = binary.BigEndian.AppendUint64(b, 0)
	b = binary.BigEndian.AppendUint32(b, uint32(len(payload)))
	return append(b, payload...)
}

func TestNativePairWorkerPacketClosedFramingAndSlackBounds(t *testing.T) {
	var transcript [32]byte
	transcript[0] = 9
	for tag, kind := range map[byte]string{1: TypeNativePairWorkerReady, 2: TypeNativePairWorkerCommand, 3: TypeNativePairWorkerEvent} {
		for _, size := range []int{1, NativePairWorkerPayloadLimit} {
			packet := workerBoundaryPacket(tag, transcript, bytes.Repeat([]byte{7}, size))
			if tag == 2 {
				binary.BigEndian.PutUint64(packet[38:46], 3600000000000)
				binary.BigEndian.PutUint64(packet[46:54], 3600000000000)
			}
			decoded, e := DecodeNativePairWorkerPacket(packet, kind, transcript)
			if e != nil || len(decoded.Payload) != size || decoded.Kind != tag {
				t.Fatal("exact packet bound refused", e)
			}
			packet[58] ^= 1
			if decoded.Payload[0] != 7 {
				t.Fatal("decoded payload aliases caller bytes")
			}
		}
	}
	for _, change := range []string{"empty", "oversized", "short", "prefix", "version", "tag", "length", "transcript", "zero-context", "attach-tag", "delivery-over", "generation-over", "ready-slack", "event-slack"} {
		t.Run(change, func(t *testing.T) {
			packet := workerBoundaryPacket(2, transcript, []byte{7})
			kind, expected := TypeNativePairWorkerCommand, transcript
			switch change {
			case "empty":
				packet = workerBoundaryPacket(2, transcript, nil)
			case "oversized":
				packet = workerBoundaryPacket(2, transcript, make([]byte, NativePairWorkerPayloadLimit+1))
			case "short":
				packet = packet[:38]
			case "prefix":
				packet[0] ^= 1
			case "version":
				packet[4]++
			case "tag":
				packet[5] = 1
			case "length":
				binary.BigEndian.PutUint32(packet[54:58], 2)
			case "transcript":
				packet[6] ^= 1
			case "zero-context":
				expected = [32]byte{}
			case "attach-tag":
				kind = TypeNativePairWorkerAttach
			case "delivery-over":
				binary.BigEndian.PutUint64(packet[38:46], 3600000000001)
			case "generation-over":
				binary.BigEndian.PutUint64(packet[46:54], 3600000000001)
			case "ready-slack":
				packet[5] = 1
				kind = TypeNativePairWorkerReady
				binary.BigEndian.PutUint64(packet[38:46], 1)
			case "event-slack":
				packet[5] = 3
				kind = TypeNativePairWorkerEvent
				binary.BigEndian.PutUint64(packet[46:54], 1)
			}
			if _, e := DecodeNativePairWorkerPacket(packet, kind, expected); e == nil {
				t.Fatal("invalid packet accepted")
			}
		})
	}
}
