package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"log"
	"math/big"
	"strings"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// deterministicP256Key derives a P-256 private key from a label so the
// public key (and thus every checked-in vector) is stable across runs.
// Signatures themselves are randomized; verification inputs are the fixture.
func deterministicP256Key(label string) *ecdsa.PrivateKey {
	curve := elliptic.P256()
	d := new(big.Int).SetBytes(deriveBytes(label, 32))
	nMinus1 := new(big.Int).Sub(curve.Params().N, big.NewInt(1))
	d.Mod(d, nMinus1).Add(d, big.NewInt(1)) // 1..N-1
	priv := new(ecdsa.PrivateKey)
	priv.Curve = curve
	priv.D = d
	priv.X, priv.Y = curve.ScalarBaseMult(d.Bytes())
	return priv
}

func p256PublicUncompressed(priv *ecdsa.PrivateKey) []byte {
	out := make([]byte, 65)
	out[0] = 0x04
	priv.X.FillBytes(out[1:33])
	priv.Y.FillBytes(out[33:65])
	return out
}

func signSHA256(priv *ecdsa.PrivateKey, payload []byte) string {
	hash := sha256.Sum256(payload)
	sig, err := ecdsa.SignASN1(rand.Reader, priv, hash[:])
	if err != nil {
		log.Fatalf("sign: %v", err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}

// seFixture is the shared Secure-Enclave-style identity: the raw signed
// attestation blob is embedded in BOTH the register__populated.json golden
// (as the json.RawMessage attestation field) and signing/vectors.json, so
// the Rust test can prove byte-exact RawValue preservation end to end: pull
// the raw bytes out of the decoded register frame and verify this signature
// over them.
type seFixtureT struct {
	key           *ecdsa.PrivateKey
	pubB64        string // 65-byte uncompressed point
	pubRaw64B64   string // 64-byte X||Y variant (CryptoKit shape)
	blobRaw       string // exact signed bytes, Swift-style \/ escapes
	blobSigB64    string
	signedAttJSON string // {"attestation":<blobRaw>,"signature":"..."}
}

var seFixture = sync.OnceValue(func() seFixtureT {
	key := deterministicP256Key("darkbloom-fixture-se-key")
	pub := p256PublicUncompressed(key)
	pubB64 := base64.StdEncoding.EncodeToString(pub)

	// Swift's JSONEncoder escapes forward slashes in strings; reproduce that
	// in the raw blob so the vector pins "verify the original bytes, never a
	// re-encode" (attestation.go SignedAttestation.AttestationRaw).
	swiftEscapedPub := strings.ReplaceAll(pubB64, "/", `\/`)
	blobRaw := fmt.Sprintf(
		`{"authenticatedRootEnabled":true,"binaryHash":"3c1f9ab2","chipName":"Apple M3 Max",`+
			`"encryptionPublicKey":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",`+
			`"hardwareModel":"Mac15,8","hypervisorActive":false,"osVersion":"15.5",`+
			`"publicKey":"%s","rdmaDisabled":true,"secureBootEnabled":true,`+
			`"secureEnclaveAvailable":true,"serialNumber":"C02XL0GYJGH5",`+
			`"sipEnabled":true,"timestamp":"2026-07-09T12:34:56Z"}`,
		swiftEscapedPub,
	)
	blobSigB64 := signSHA256(key, []byte(blobRaw))

	return seFixtureT{
		key:           key,
		pubB64:        pubB64,
		pubRaw64B64:   base64.StdEncoding.EncodeToString(pub[1:]),
		blobRaw:       blobRaw,
		blobSigB64:    blobSigB64,
		signedAttJSON: fmt.Sprintf(`{"attestation":%s,"signature":"%s"}`, blobRaw, blobSigB64),
	}
})

// signedAttestationJSON is the SignedAttestation-shaped raw JSON used as
// RegisterMessage.Attestation in the json_v1 goldens.
func signedAttestationJSON() string {
	return seFixture().signedAttJSON
}

// statusInputJSON mirrors attestation.StatusCanonicalInput with the wire
// field names the Rust StatusCanonicalInput test rebuilds from.
type statusInputJSON struct {
	Nonce             string            `json:"nonce"`
	Timestamp         string            `json:"timestamp"`
	HypervisorActive  *bool             `json:"hypervisor_active,omitempty"`
	RDMADisabled      *bool             `json:"rdma_disabled,omitempty"`
	SIPEnabled        *bool             `json:"sip_enabled,omitempty"`
	SecureBootEnabled *bool             `json:"secure_boot_enabled,omitempty"`
	BinaryHash        string            `json:"binary_hash,omitempty"`
	ActiveModelHash   string            `json:"active_model_hash,omitempty"`
	PythonHash        string            `json:"python_hash,omitempty"`
	RuntimeHash       string            `json:"runtime_hash,omitempty"`
	TemplateHashes    map[string]string `json:"template_hashes,omitempty"`
	GrpcBinaryHash    string            `json:"grpc_binary_hash,omitempty"`
	ModelHashes       map[string]string `json:"model_hashes,omitempty"`
}

type statusVector struct {
	Input        statusInputJSON `json:"input"`
	CanonicalB64 string          `json:"canonical_b64"`
	SignatureB64 string          `json:"signature_b64"`
}

type signingVectors struct {
	SEPublicKeyB64      string `json:"se_public_key_b64"`
	SEPublicKeyRaw64B64 string `json:"se_public_key_raw64_b64"`

	Challenge struct {
		NonceB64     string `json:"nonce_b64"`
		Timestamp    string `json:"timestamp"`
		Data         string `json:"data"`
		SignatureB64 string `json:"signature_b64"`
	} `json:"challenge"`

	StatusFull    statusVector `json:"status_full"`
	StatusMinimal statusVector `json:"status_minimal"`

	RawBlob struct {
		BlobB64      string `json:"blob_b64"`
		SignatureB64 string `json:"signature_b64"`
	} `json:"raw_blob"`
}

func writeSigningVectors(dir string) {
	fx := seFixture()
	boolPtr := func(v bool) *bool { return &v }

	var v signingVectors
	v.SEPublicKeyB64 = fx.pubB64
	v.SEPublicKeyRaw64B64 = fx.pubRaw64B64

	// Challenge: the provider signs SHA-256(nonce_b64_string + timestamp)
	// (provider.go: challengeData := pc.nonce + pc.timestamp).
	nonceB64 := base64.StdEncoding.EncodeToString(deriveBytes("darkbloom-fixture-challenge-nonce", 32))
	timestamp := "2026-07-09T12:34:56Z"
	data := nonceB64 + timestamp
	v.Challenge.NonceB64 = nonceB64
	v.Challenge.Timestamp = timestamp
	v.Challenge.Data = data
	v.Challenge.SignatureB64 = signSHA256(fx.key, []byte(data))

	// Status canonical: full input exercises every field (including the
	// legacy hypervisor_active pointer and nested sorted maps); minimal
	// pins the omission rules.
	fullInput := attestation.StatusCanonicalInput{
		Nonce:             nonceB64,
		Timestamp:         timestamp,
		HypervisorActive:  boolPtr(false),
		RDMADisabled:      boolPtr(true),
		SIPEnabled:        boolPtr(true),
		SecureBootEnabled: boolPtr(true),
		BinaryHash:        "3c1f9ab2",
		ActiveModelHash:   "0be6ff1c9e3a8d5f",
		PythonHash:        "p-hash",
		RuntimeHash:       "r-hash",
		TemplateHashes:    map[string]string{"chatml": "aa11", "gemma": "bb22"},
		GrpcBinaryHash:    "grpc-hash",
		ModelHashes:       map[string]string{"gemma-4-26b-8bit": "ffee", "qwen-3-8b-4bit": "0be6"},
	}
	fullCanonical, err := attestation.BuildStatusCanonical(fullInput)
	if err != nil {
		log.Fatalf("build full canonical: %v", err)
	}
	v.StatusFull = statusVector{
		Input: statusInputJSON{
			Nonce:             fullInput.Nonce,
			Timestamp:         fullInput.Timestamp,
			HypervisorActive:  fullInput.HypervisorActive,
			RDMADisabled:      fullInput.RDMADisabled,
			SIPEnabled:        fullInput.SIPEnabled,
			SecureBootEnabled: fullInput.SecureBootEnabled,
			BinaryHash:        fullInput.BinaryHash,
			ActiveModelHash:   fullInput.ActiveModelHash,
			PythonHash:        fullInput.PythonHash,
			RuntimeHash:       fullInput.RuntimeHash,
			TemplateHashes:    fullInput.TemplateHashes,
			GrpcBinaryHash:    fullInput.GrpcBinaryHash,
			ModelHashes:       fullInput.ModelHashes,
		},
		CanonicalB64: base64.StdEncoding.EncodeToString(fullCanonical),
		SignatureB64: signSHA256(fx.key, fullCanonical),
	}

	minimalInput := attestation.StatusCanonicalInput{
		Nonce:     nonceB64,
		Timestamp: timestamp,
	}
	minimalCanonical, err := attestation.BuildStatusCanonical(minimalInput)
	if err != nil {
		log.Fatalf("build minimal canonical: %v", err)
	}
	v.StatusMinimal = statusVector{
		Input: statusInputJSON{
			Nonce:     minimalInput.Nonce,
			Timestamp: minimalInput.Timestamp,
		},
		CanonicalB64: base64.StdEncoding.EncodeToString(minimalCanonical),
		SignatureB64: signSHA256(fx.key, minimalCanonical),
	}

	// Raw blob: signature over the EXACT raw bytes (Swift \/ escapes and
	// all). The same bytes ride inside register__populated.json.
	v.RawBlob.BlobB64 = base64.StdEncoding.EncodeToString([]byte(fx.blobRaw))
	v.RawBlob.SignatureB64 = fx.blobSigB64

	writeFile(dir, "vectors.json", v)
}
