package protocol

import (
	"bytes"
	"encoding/json"
	"testing"
)

// TestModelInfoIsVisionSymmetry verifies the v0.6.0 is_vision field round-trips
// and is omitted when false, so a text-only build is wire-compatible with
// pre-0.6.0 providers (which never send it and decode it as false).
func TestModelInfoIsVisionSymmetry(t *testing.T) {
	// Vision build: is_vision present and true.
	vis := ModelInfo{ID: "gemma-4-26b-qat-4bit", SizeBytes: 1, IsVision: true}
	b, err := json.Marshal(vis)
	if err != nil {
		t.Fatalf("marshal vision: %v", err)
	}
	if !bytes.Contains(b, []byte(`"is_vision":true`)) {
		t.Fatalf("expected is_vision:true in JSON, got %s", b)
	}
	var back ModelInfo
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal vision: %v", err)
	}
	if !back.IsVision {
		t.Fatal("expected IsVision=true after round-trip")
	}

	// Text-only build: is_vision omitted entirely (omitempty), and a payload with
	// no is_vision key decodes to false.
	text := ModelInfo{ID: "gpt-oss-20b", SizeBytes: 1}
	b, err = json.Marshal(text)
	if err != nil {
		t.Fatalf("marshal text: %v", err)
	}
	if bytes.Contains(b, []byte("is_vision")) {
		t.Fatalf("expected is_vision to be omitted for a text-only build, got %s", b)
	}
	var legacy ModelInfo
	if err := json.Unmarshal([]byte(`{"id":"gpt-oss-20b","size_bytes":1}`), &legacy); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	if legacy.IsVision {
		t.Fatal("expected IsVision=false when the field is absent (pre-0.6.0 provider)")
	}
}

// TestModelInfoTemplateRenderOKSymmetry verifies the tri-state
// template_render_ok field survives the wire: true encodes, FALSE ENCODES
// (pointer false is the exclusion signal — omitempty must not drop it), nil is
// omitted entirely, and an absent key decodes back to nil (pre-0.6.5 provider,
// no opinion).
func TestModelInfoTemplateRenderOKSymmetry(t *testing.T) {
	// Self-check passed: template_render_ok present and true.
	renderOK := true
	pass := ModelInfo{ID: "gemma-4-26b-qat-4bit", SizeBytes: 1, TemplateRenderOK: &renderOK}
	b, err := json.Marshal(pass)
	if err != nil {
		t.Fatalf("marshal render-ok: %v", err)
	}
	if !bytes.Contains(b, []byte(`"template_render_ok":true`)) {
		t.Fatalf("expected template_render_ok:true in JSON, got %s", b)
	}
	var back ModelInfo
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal render-ok: %v", err)
	}
	if back.TemplateRenderOK == nil || !*back.TemplateRenderOK {
		t.Fatalf("expected TemplateRenderOK=*true after round-trip, got %v", back.TemplateRenderOK)
	}

	// Self-check FAILED: pointer false must encode and round-trip — it is the
	// signal that excludes the provider from tool-bearing requests.
	renderBroken := false
	fail := ModelInfo{ID: "gemma-4-26b-qat-4bit", SizeBytes: 1, TemplateRenderOK: &renderBroken}
	b, err = json.Marshal(fail)
	if err != nil {
		t.Fatalf("marshal render-broken: %v", err)
	}
	if !bytes.Contains(b, []byte(`"template_render_ok":false`)) {
		t.Fatalf("pointer false must survive omitempty and encode, got %s", b)
	}
	back = ModelInfo{}
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal render-broken: %v", err)
	}
	if back.TemplateRenderOK == nil || *back.TemplateRenderOK {
		t.Fatalf("expected TemplateRenderOK=*false after round-trip, got %v", back.TemplateRenderOK)
	}

	// Pre-0.6.5 provider: nil omits the key, and a payload without the key
	// decodes to nil (no opinion), never to false.
	legacy := ModelInfo{ID: "gpt-oss-20b", SizeBytes: 1}
	b, err = json.Marshal(legacy)
	if err != nil {
		t.Fatalf("marshal legacy: %v", err)
	}
	if bytes.Contains(b, []byte("template_render_ok")) {
		t.Fatalf("expected template_render_ok to be omitted when nil, got %s", b)
	}
	var decoded ModelInfo
	if err := json.Unmarshal([]byte(`{"id":"gpt-oss-20b","size_bytes":1}`), &decoded); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	if decoded.TemplateRenderOK != nil {
		t.Fatalf("expected TemplateRenderOK=nil when the field is absent, got %v", *decoded.TemplateRenderOK)
	}
}

func TestProviderMessageUnmarshalLoadModelStatus(t *testing.T) {
	data := []byte(`{"type":"load_model_status","model_id":"qwen","status":"failed","error":"GPU OOM"}`)

	var msg ProviderMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if msg.Type != TypeLoadModelStatus {
		t.Fatalf("Type=%q, want %q", msg.Type, TypeLoadModelStatus)
	}
	status, ok := msg.Payload.(*LoadModelStatusMessage)
	if !ok {
		t.Fatalf("Payload=%T, want *LoadModelStatusMessage", msg.Payload)
	}
	if status.ModelID != "qwen" || status.Status != LoadModelStatusFailed || status.Error != "GPU OOM" {
		t.Fatalf("decoded status = %+v", status)
	}
}

func TestPrefetchModelMessageMarshal(t *testing.T) {
	msg := PrefetchModelMessage{
		Type:     TypePrefetchModel,
		ModelID:  "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
		Priority: 5,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var out PrefetchModelMessage
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.Type != TypePrefetchModel || out.ModelID != msg.ModelID || out.Priority != 5 {
		t.Fatalf("round-trip mismatch: %+v", out)
	}

	// Priority is omitempty: a zero priority must not appear on the wire so
	// the Swift `if p.priority != 0` mirror stays byte-compatible.
	zero, _ := json.Marshal(PrefetchModelMessage{Type: TypePrefetchModel, ModelID: "m"})
	if bytes.Contains(zero, []byte("priority")) {
		t.Fatalf("zero priority should be omitted: %s", zero)
	}
}

func TestProviderMessageUnmarshalPrefetchModelStatus(t *testing.T) {
	data := []byte(`{"type":"prefetch_model_status","model_id":"gemma","status":"downloading","bytes_done":1048576,"bytes_total":15600000000}`)

	var msg ProviderMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if msg.Type != TypePrefetchModelStatus {
		t.Fatalf("Type=%q, want %q", msg.Type, TypePrefetchModelStatus)
	}
	status, ok := msg.Payload.(*PrefetchModelStatusMessage)
	if !ok {
		t.Fatalf("Payload=%T, want *PrefetchModelStatusMessage", msg.Payload)
	}
	if status.ModelID != "gemma" || status.Status != PrefetchModelStatusDownloading {
		t.Fatalf("decoded status = %+v", status)
	}
	if status.BytesDone != 1048576 || status.BytesTotal != 15600000000 {
		t.Fatalf("byte counts = %d/%d", status.BytesDone, status.BytesTotal)
	}
}

func TestProviderMessageUnmarshalModelsUpdate(t *testing.T) {
	// The wire form a provider sends after a verified prefetch (mirrors the
	// Swift ModelInfo encoding used by `register`).
	data := []byte(`{"type":"models_update","models":[{"id":"mlx-community/gemma-4-26B-A4B-it-qat-4bit","size_bytes":15600000000,"model_type":"chat","quantization":"4bit","weight_hash":"abc123"}]}`)

	var msg ProviderMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if msg.Type != TypeModelsUpdate {
		t.Fatalf("Type=%q, want %q", msg.Type, TypeModelsUpdate)
	}
	upd, ok := msg.Payload.(*ModelsUpdateMessage)
	if !ok {
		t.Fatalf("Payload=%T, want *ModelsUpdateMessage", msg.Payload)
	}
	if len(upd.Models) != 1 {
		t.Fatalf("models len = %d, want 1", len(upd.Models))
	}
	m := upd.Models[0]
	if m.ID != "mlx-community/gemma-4-26B-A4B-it-qat-4bit" || m.ModelType != "chat" || m.WeightHash != "abc123" {
		t.Fatalf("decoded model = %+v", m)
	}
}

func TestProviderMessageUnmarshalLMStudioModelsUpdate(t *testing.T) {
	data := []byte(`{"type":"lmstudio_models_update","models":[{"id":"lmstudio/laguna","size_bytes":1024,"model_type":"chat","quantization":"4bit"}]}`)

	var msg ProviderMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if msg.Type != TypeLMStudioModelsUpdate {
		t.Fatalf("Type=%q, want %q", msg.Type, TypeLMStudioModelsUpdate)
	}
	update, ok := msg.Payload.(*LMStudioModelsUpdateMessage)
	if !ok || len(update.Models) != 1 || update.Models[0].ID != "lmstudio/laguna" {
		t.Fatalf("decoded update = %#v", msg.Payload)
	}
}

func TestPrefetchModelStatusVerifiedRoundTrip(t *testing.T) {
	msg := PrefetchModelStatusMessage{
		Type:    TypePrefetchModelStatus,
		ModelID: "gemma",
		Status:  PrefetchModelStatusVerified,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// Zero byte counts are omitempty (terminal "verified" carries no progress).
	if bytes.Contains(data, []byte("bytes_done")) || bytes.Contains(data, []byte("bytes_total")) {
		t.Fatalf("zero byte counts should be omitted: %s", data)
	}
	var pm ProviderMessage
	if err := json.Unmarshal(data, &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	status := pm.Payload.(*PrefetchModelStatusMessage)
	if status.Status != PrefetchModelStatusVerified || status.BytesDone != 0 {
		t.Fatalf("decoded = %+v", status)
	}
}

// TestDesiredModelsMessageMarshal verifies the desired_models wire shape the
// coordinator emits round-trips, including the snake_case keys the Swift decoder
// expects and the omitempty behavior of previous_build (so Go's omission ↔ the
// Swift optional). This is the protocol-symmetry guard for desired_models.
func TestDesiredModelsMessageMarshal(t *testing.T) {
	msg := DesiredModelsMessage{
		Type: TypeDesiredModels,
		Models: []DesiredModelEntry{
			{ModelName: "gemma-4-26b", DesiredBuild: "mlx-community/gemma-4-26B-A4B-it-qat-4bit", PreviousBuild: "mlx-community/gemma-4-26b-a4b-it-fp8"},
			{ModelName: "qwen3.5-9b", DesiredBuild: "mlx-community/Qwen3.5-9B-MLX-4bit"}, // no previous
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	// Exact wire-key expectations.
	s := string(data)
	for _, want := range []string{`"type":"desired_models"`, `"model_name":"gemma-4-26b"`, `"desired_build":"mlx-community/gemma-4-26B-A4B-it-qat-4bit"`, `"previous_build":"mlx-community/gemma-4-26b-a4b-it-fp8"`} {
		if !bytes.Contains(data, []byte(want)) {
			t.Errorf("marshaled JSON missing %q: %s", want, s)
		}
	}
	// previous_build is omitempty: the second entry (no previous) must not emit it.
	if c := bytes.Count(data, []byte(`"previous_build"`)); c != 1 {
		t.Errorf("previous_build should appear exactly once (omitempty), got %d in %s", c, s)
	}

	var decoded DesiredModelsMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.Type != TypeDesiredModels {
		t.Errorf("type = %q, want %q", decoded.Type, TypeDesiredModels)
	}
	if len(decoded.Models) != 2 {
		t.Fatalf("models len = %d, want 2", len(decoded.Models))
	}
	if decoded.Models[0].ModelName != "gemma-4-26b" || decoded.Models[0].PreviousBuild != "mlx-community/gemma-4-26b-a4b-it-fp8" {
		t.Errorf("entry 0 round-trip mismatch: %+v", decoded.Models[0])
	}
	if decoded.Models[1].PreviousBuild != "" {
		t.Errorf("entry 1 previous_build should be empty, got %q", decoded.Models[1].PreviousBuild)
	}
}
