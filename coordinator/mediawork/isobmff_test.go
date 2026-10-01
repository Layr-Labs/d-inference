package mediawork

import (
	"context"
	"encoding/binary"
	"testing"
)

func testAtom(kind string, pieces ...[]byte) []byte {
	n := 8
	for _, p := range pieces {
		n += len(p)
	}
	b := make([]byte, 8, n)
	binary.BigEndian.PutUint32(b, uint32(n))
	copy(b[4:], kind)
	for _, p := range pieces {
		b = append(b, p...)
	}
	return b
}

func testTrack(kind string, w, h, frames, step, scale int) []byte {
	hdlr := make([]byte, 12)
	copy(hdlr[8:], kind)
	mdhd := make([]byte, 20)
	binary.BigEndian.PutUint32(mdhd[12:], uint32(scale))
	stts := make([]byte, 16)
	binary.BigEndian.PutUint32(stts[4:], 1)
	binary.BigEndian.PutUint32(stts[8:], uint32(frames))
	binary.BigEndian.PutUint32(stts[12:], uint32(step))
	entry := make([]byte, 78)
	binary.BigEndian.PutUint16(entry[24:], uint16(w))
	binary.BigEndian.PutUint16(entry[26:], uint16(h))
	codec := "avc1"
	if kind == "soun" {
		codec = "mp4a"
	}
	stsd := make([]byte, 8)
	binary.BigEndian.PutUint32(stsd[4:], 1)
	return testAtom("trak", testAtom("mdia", testAtom("mdhd", mdhd), testAtom("hdlr", hdlr), testAtom("minf", testAtom("stbl", testAtom("stts", stts), testAtom("stsd", stsd, testAtom(codec, entry))))))
}

func TestEncodedMovieUsesTrackSamplesAndAudio(t *testing.T) {
	p := testProfile(t)
	video := testTrack("vide", 1280, 720, 150, 1000, 30000)
	file := testAtom("moov", video)
	if n, ok := p.EncodedVideo(context.Background(), uri("video/mp4", file)); !ok || n != 3550 {
		t.Fatalf("silent%d,%v", n, ok)
	}
	file = testAtom("moov", video, testTrack("soun", 0, 0, 240, 1024, 48000))
	audio, _ := p.audioTokens(5.12)
	if n, ok := p.EncodedVideo(context.Background(), uri("video/quicktime", file)); !ok || n != 3550+audio+6 {
		t.Fatalf("AV%d,%v want%d", n, ok, 3550+audio+6)
	}
	file = append(file, testAtom("moof", nil)...)
	if _, ok := p.EncodedVideo(context.Background(), uri("video/mp4", file)); ok {
		t.Fatal("fragmented stream guessed")
	}
	file = testAtom("moov", video, video)
	if _, ok := p.EncodedVideo(context.Background(), uri("video/mp4", file)); ok {
		t.Fatal("multiple video tracks guessed")
	}
}

func TestEncodedMovieRejectsMalformedMetadata(t *testing.T) {
	p := testProfile(t)
	for _, file := range [][]byte{{}, {0, 0, 0, 4, 'm', 'o', 'o', 'v'}, testAtom("moov", []byte{1, 2, 3}), testAtom("moov", testTrack("vide", 0, 0, 150, 1000, 30000)), testAtom("moov", testTrack("vide", 1280, 720, 150, 0, 30000))} {
		if _, ok := p.EncodedVideo(context.Background(), uri("video/mp4", file)); ok {
			t.Fatalf("malformed accepted len%d", len(file))
		}
	}
}

func FuzzNativeMediaMetadata(f *testing.F) {
	f.Add([]byte("invalid"))
	f.Add(testAtom("moov", testTrack("vide", 1280, 720, 150, 1000, 30000)))
	p := &Profile{patch: 16, merge: 2, temporal: 2, imageMin: 8192, imageMax: 8388608, videoMin: 8192, videoMax: 8388608, videoTotal: 268435456, fps: 1, minFrames: 8, maxFrames: 3600, audio: true}
	f.Fuzz(func(t *testing.T, data []byte) {
		if len(data) > 65536 {
			t.Skip()
		}
		p.EncodedVideo(context.Background(), uri("video/mp4", data))
		p.EncodedAudio(context.Background(), uri("audio/wav", data), false)
		p.EncodedImage(context.Background(), uri("image/png", data))
	})
}
