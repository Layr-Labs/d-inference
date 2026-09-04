package api

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
	"unsafe"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestStrayChunkKeyDoesNotAliasScannedFrame: the request id of a scanned
// chunk frame shares one allocation with the frame's ciphertext; a stray-chunk
// entry keyed by it must own a copy, so the entry (5 min TTL, up to
// zombieMaxEntries of them) pins only the id, not the whole frame.
func TestStrayChunkKeyDoesNotAliasScannedFrame(t *testing.T) {
	frame := `{"type":"inference_response_chunk","request_id":"stray-alias-req","encrypted_data":{"ephemeral_public_key":"AAAA","ciphertext":"` +
		strings.Repeat("Q", 4096) + `"}}`
	var pm protocol.ProviderMessage
	if err := json.Unmarshal([]byte(frame), &pm); err != nil {
		t.Fatalf("decode chunk frame: %v", err)
	}
	msg, ok := pm.Payload.(*protocol.InferenceResponseChunkMessage)
	if !ok || msg.EncryptedData == nil {
		t.Fatalf("frame did not decode as a chunk with encrypted data: %T", pm.Payload)
	}
	// Precondition: the scanner's single-allocation layout (id, data,
	// ephemeral, ciphertext back to back). If it ever changes, this test must
	// be revisited rather than passing vacuously.
	idPtr := uintptr(unsafe.Pointer(unsafe.StringData(msg.RequestID)))
	ctPtr := uintptr(unsafe.Pointer(unsafe.StringData(msg.EncryptedData.Ciphertext)))
	if want := uintptr(len(msg.RequestID) + len(msg.Data) + len(msg.EncryptedData.EphemeralPublicKey)); ctPtr-idPtr != want {
		t.Fatalf("scanned request id does not share the frame allocation (ciphertext at +%d, want +%d): precondition changed", ctPtr-idPtr, want)
	}

	z := newZombieStreamCanceller()
	res := z.strayChunk(msg.RequestID, time.Now())
	if !res.send || res.cause != cancelCauseStrayChunk {
		t.Fatalf("stray chunk result = %+v, want an immediate stray_chunk cancel", res)
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	if len(z.entries) != 1 {
		t.Fatalf("entries = %d, want 1", len(z.entries))
	}
	for key := range z.entries {
		if key != msg.RequestID {
			t.Fatalf("entry key = %q, want %q", key, msg.RequestID)
		}
		if unsafe.StringData(key) == unsafe.StringData(msg.RequestID) {
			t.Fatal("stray-chunk entry key aliases the scanned frame allocation (pins the whole frame for the entry TTL)")
		}
	}
}
