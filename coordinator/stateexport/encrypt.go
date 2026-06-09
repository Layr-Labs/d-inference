package stateexport

import (
	"fmt"
	"io"
	"strings"

	"filippo.io/age"
)

// ValidateRecipient parses an age recipient string (e.g. "age1...") and returns
// a clear error rather than leaking the raw value. Used to fail fast before any
// response header is written.
func ValidateRecipient(recipient string) error {
	_, err := parseRecipient(recipient)
	return err
}

func parseRecipient(recipient string) (age.Recipient, error) {
	recipient = strings.TrimSpace(recipient)
	if recipient == "" {
		return nil, fmt.Errorf("empty age recipient")
	}
	// A bech32 age X25519 recipient is ~62 chars; cap well above that to reject
	// absurd input before handing it to the parser.
	if len(recipient) > 512 {
		return nil, fmt.Errorf("age recipient too long")
	}
	r, err := age.ParseX25519Recipient(recipient)
	if err != nil {
		return nil, fmt.Errorf("invalid age recipient (expected an age1... X25519 recipient): %w", err)
	}
	return r, nil
}

// EncryptWriter wraps dst with age streaming encryption for the given recipient
// string. The returned WriteCloser MUST be closed to flush age's final chunk and
// write a valid stream — the caller is responsible for closing it (and should do
// so before treating the encrypted output as complete).
//
// age performs streaming (chunked) encryption, so the archive is never buffered
// whole in memory: zip writer -> age writer -> http.ResponseWriter.
func EncryptWriter(dst io.Writer, recipient string) (io.WriteCloser, error) {
	r, err := parseRecipient(recipient)
	if err != nil {
		return nil, err
	}
	wc, err := age.Encrypt(dst, r)
	if err != nil {
		return nil, fmt.Errorf("init age encryption: %w", err)
	}
	return wc, nil
}
