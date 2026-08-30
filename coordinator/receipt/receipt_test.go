package receipt

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// sampleReceipt mirrors fixtures/receipts/receipt_vectors.json vector 0.
// The Swift twin test (InferenceReceiptTests) consumes the same fixture, so
// the canonical bytes and address here are the cross-language contract.
func sampleReceipt() Receipt {
	return Receipt{
		CompletionTokens: 42,
		ModelID:          "mlx-community/gemma-4-26b",
		ModelWeightHash:  strings.Repeat("ab", 32),
		PromptTokens:     17,
		RequestID:        "req-0001",
		RequestSHA256:    strings.Repeat("12", 32),
		ResponseSHA256:   strings.Repeat("34", 32),
		V:                Version,
	}
}

func TestCanonicalFormIsStable(t *testing.T) {
	got := string(sampleReceipt().Canonical())
	want := `{"completion_tokens":42,` +
		`"model_id":"mlx-community/gemma-4-26b",` +
		`"model_weight_hash":"` + strings.Repeat("ab", 32) + `",` +
		`"prompt_tokens":17,` +
		`"request_id":"req-0001",` +
		`"request_sha256":"` + strings.Repeat("12", 32) + `",` +
		`"response_sha256":"` + strings.Repeat("34", 32) + `",` +
		`"v":2}`
	if got != want {
		t.Fatalf("canonical form drifted:\n got  %s\n want %s", got, want)
	}
	// Canonical form must also be valid JSON that round-trips.
	var check map[string]any
	if err := json.Unmarshal([]byte(got), &check); err != nil {
		t.Fatalf("canonical form is not valid JSON: %v", err)
	}
	if len(check) != 8 {
		t.Fatalf("canonical form has %d fields, want 8", len(check))
	}
}

func TestGoldenVectors(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "receipts", "receipt_vectors.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var vectors []struct {
		Name      string          `json:"name"`
		Receipt   json.RawMessage `json:"receipt"`
		Canonical string          `json:"canonical"`
		Address   string          `json:"address"`
	}
	if err := json.Unmarshal(data, &vectors); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	if len(vectors) == 0 {
		t.Fatal("fixture has no vectors")
	}
	for _, v := range vectors {
		t.Run(v.Name, func(t *testing.T) {
			var r Receipt
			if err := json.Unmarshal(v.Receipt, &r); err != nil {
				t.Fatalf("unmarshal receipt: %v", err)
			}
			if got := string(r.Canonical()); got != v.Canonical {
				t.Errorf("canonical mismatch:\n got  %s\n want %s", got, v.Canonical)
			}
			if got := r.Address(); got != v.Address {
				t.Errorf("address mismatch: got %s want %s", got, v.Address)
			}
			// Wire-byte addressing must agree with struct addressing for
			// canonical bytes.
			if got := AddressOf([]byte(v.Canonical)); got != v.Address {
				t.Errorf("AddressOf mismatch: got %s want %s", got, v.Address)
			}
			// Canonical bytes must parse strictly.
			parsed, err := Parse([]byte(v.Canonical))
			if err != nil {
				t.Fatalf("Parse rejected canonical bytes: %v", err)
			}
			if parsed != r {
				t.Errorf("parse round-trip mismatch: %+v vs %+v", parsed, r)
			}
		})
	}
}

func TestParseRejectsNonCanonicalForms(t *testing.T) {
	canonical := string(sampleReceipt().Canonical())
	bad := map[string]string{
		"whitespace":       strings.Replace(canonical, ":", ": ", 1),
		"reordered keys":   `{"v":2,` + canonical[1:len(canonical)-len(`,"v":2}`)] + `}`,
		"unknown field":    canonical[:len(canonical)-1] + `,"extra":1}`,
		"trailing data":    canonical + "x",
		"uppercase hex":    strings.Replace(canonical, strings.Repeat("ab", 32), strings.Repeat("AB", 32), 1),
		"short digest":     strings.Replace(canonical, strings.Repeat("12", 32), strings.Repeat("12", 31), 1),
		"wrong version":    strings.Replace(canonical, `"v":2`, `"v":1`, 1),
		"empty request id": strings.Replace(canonical, `"request_id":"req-0001"`, `"request_id":""`, 1),
		"empty object":     `{}`,
		"not json":         `hello`,
	}
	for name, input := range bad {
		if _, err := Parse([]byte(input)); err == nil {
			t.Errorf("%s: Parse accepted non-canonical/invalid input: %s", name, input)
		}
	}
}

// TestParseAcceptsEmptyWeightHash: a provider that has not hashed its model
// yet still emits a valid receipt with model_weight_hash "".
func TestParseAcceptsEmptyWeightHash(t *testing.T) {
	r := sampleReceipt()
	r.ModelWeightHash = ""
	if _, err := Parse(r.Canonical()); err != nil {
		t.Fatalf("Parse rejected empty weight hash: %v", err)
	}
}

func testKey(t *testing.T) (*ecdsa.PrivateKey, string) {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	raw := elliptic.Marshal(elliptic.P256(), priv.PublicKey.X, priv.PublicKey.Y)
	return priv, base64.StdEncoding.EncodeToString(raw)
}

// signAddress signs exactly as the Swift Secure Enclave does: DER ECDSA over
// SHA-256 of the UTF-8 bytes of the address string.
func signAddress(t *testing.T, priv *ecdsa.PrivateKey, address string) string {
	t.Helper()
	digest := sha256.Sum256([]byte(address))
	der, err := ecdsa.SignASN1(rand.Reader, priv, digest[:])
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

func TestVerifySignature(t *testing.T) {
	priv, pubB64 := testKey(t)
	addr := sampleReceipt().Address()
	sig := signAddress(t, priv, addr)

	if err := VerifySignature(addr, sig, pubB64); err != nil {
		t.Fatalf("genuine signature rejected: %v", err)
	}

	// Tamper matrix: every mutation must fail loudly.
	otherPriv, otherPubB64 := testKey(t)
	otherAddr := AddressOf([]byte("different bytes"))
	cases := map[string][3]string{
		"wrong key":         {addr, sig, otherPubB64},
		"wrong address":     {otherAddr, sig, pubB64},
		"foreign signature": {addr, signAddress(t, otherPriv, addr), pubB64},
		"garbage signature": {addr, base64.StdEncoding.EncodeToString([]byte("nope")), pubB64},
		"garbage base64":    {addr, "!!!", pubB64},
		"garbage pubkey":    {addr, sig, "AAAA"},
	}
	for name, c := range cases {
		if err := VerifySignature(c[0], c[1], c[2]); err == nil {
			t.Errorf("%s: tampered signature verified", name)
		}
	}
}

func TestVerifyEndToEnd(t *testing.T) {
	priv, pubB64 := testKey(t)
	requestBody := []byte(`{"model":"mlx-community/gemma-4-26b","messages":[{"role":"user","content":"capital of France?"}],"temperature":0,"seed":7}`)
	responseText := "The capital of France is Paris."

	r := sampleReceipt()
	r.RequestSHA256 = SHA256Hex(requestBody)
	r.ResponseSHA256 = SHA256Hex([]byte(responseText))
	wire := r.Canonical()
	addr := AddressOf(wire)
	sig := signAddress(t, priv, addr)

	in := VerifyInput{
		ReceiptJSON:       wire,
		ResponseHash:      addr,
		SESignatureB64:    sig,
		SEPublicKeyB64:    pubB64,
		DispatchedSHA256:  SHA256Hex(requestBody),
		CatalogWeightHash: r.ModelWeightHash,
	}
	parsed, checks, err := Verify(in)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if parsed != r {
		t.Fatalf("parsed receipt mismatch")
	}
	if !checks.OK() || !checks.AddressMatch || !checks.RequestDigestMatch ||
		!checks.ModelWeightHashMatch || !checks.SignatureValid {
		t.Fatalf("genuine receipt failed checks: %+v", checks)
	}
	if !checks.RequestDigestChecked || !checks.ModelWeightHashChecked || !checks.SignatureChecked {
		t.Fatalf("checks not marked as performed: %+v", checks)
	}

	t.Run("tampered request byte fails digest check", func(t *testing.T) {
		bad := in
		tampered := append([]byte(nil), requestBody...)
		tampered[len(tampered)-2] ^= 1
		bad.DispatchedSHA256 = SHA256Hex(tampered)
		_, checks, err := Verify(bad)
		if err != nil {
			t.Fatalf("Verify: %v", err)
		}
		if checks.OK() || checks.RequestDigestMatch {
			t.Fatalf("tampered request passed: %+v", checks)
		}
	})

	t.Run("model substitution fails weight hash check", func(t *testing.T) {
		bad := in
		bad.CatalogWeightHash = strings.Repeat("cd", 32)
		_, checks, err := Verify(bad)
		if err != nil {
			t.Fatalf("Verify: %v", err)
		}
		if checks.OK() || checks.ModelWeightHashMatch {
			t.Fatalf("substituted model passed: %+v", checks)
		}
	})

	t.Run("forged receipt fails address check", func(t *testing.T) {
		forged := r
		forged.CompletionTokens = 1
		bad := in
		bad.ReceiptJSON = forged.Canonical() // response_hash still the original
		_, checks, err := Verify(bad)
		if err != nil {
			t.Fatalf("Verify: %v", err)
		}
		if checks.OK() || checks.AddressMatch {
			t.Fatalf("forged receipt passed: %+v", checks)
		}
	})

	t.Run("resigned forgery fails request digest binding", func(t *testing.T) {
		// A malicious provider CAN mint a well-formed receipt over a lie and
		// sign it. The coordinator's dispatched-body digest refutes it.
		forged := r
		forged.RequestSHA256 = strings.Repeat("ee", 32)
		wire := forged.Canonical()
		addr := AddressOf(wire)
		bad := VerifyInput{
			ReceiptJSON:       wire,
			ResponseHash:      addr,
			SESignatureB64:    signAddress(t, priv, addr),
			SEPublicKeyB64:    pubB64,
			DispatchedSHA256:  SHA256Hex(requestBody),
			CatalogWeightHash: r.ModelWeightHash,
		}
		_, checks, err := Verify(bad)
		if err != nil {
			t.Fatalf("Verify: %v", err)
		}
		if checks.OK() || checks.RequestDigestMatch {
			t.Fatalf("resigned forgery passed: %+v", checks)
		}
		if !checks.AddressMatch || !checks.SignatureValid {
			t.Fatalf("forgery should be internally consistent (that is the point): %+v", checks)
		}
	})

	t.Run("unchecked bindings are tri-state, not silently OK", func(t *testing.T) {
		bare := VerifyInput{ReceiptJSON: wire, ResponseHash: addr}
		_, checks, err := Verify(bare)
		if err != nil {
			t.Fatalf("Verify: %v", err)
		}
		if checks.SignatureChecked || checks.RequestDigestChecked || checks.ModelWeightHashChecked {
			t.Fatalf("checks claimed without inputs: %+v", checks)
		}
		if !checks.OK() {
			t.Fatalf("address-only verification should pass OK(): %+v", checks)
		}
	})
}

func TestEncodeJSONStringEscaping(t *testing.T) {
	cases := map[string]string{
		`plain`:      `"plain"`,
		`sla/sh`:     `"sla/sh"`, // no slash escaping (Swift: .withoutEscapingSlashes)
		`qu"ote`:     `"qu\"ote"`,
		`back\slash`: `"back\\slash"`,
		"tab\tnl\n":  `"tab\tnl\n"`,
		"ctrl\x01":   `"ctrl\u0001"`,
		`<html>&`:    `"<html>&"`, // no HTML escaping
		"unicodé-κ":  `"unicodé-κ"`,
	}
	for in, want := range cases {
		if got := encodeJSONString(in); got != want {
			t.Errorf("encodeJSONString(%q) = %s, want %s", in, got, want)
		}
	}
}
