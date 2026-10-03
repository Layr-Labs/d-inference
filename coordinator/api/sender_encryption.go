// sender_encryption.go implements optional sender→coordinator request encryption.
//
// Senders fetch the coordinator's long-lived X25519 public key from
// GET /v1/encryption-key, NaCl-Box-seal their request body to it, and POST as
// Content-Type: application/eigeninference-sealed+json. The middleware below
// transparently decrypts the body so downstream handlers see plaintext, and
// re-seals the response (both buffered JSON and SSE streams) using the
// sender's ephemeral public key from the request envelope.
//
// Plaintext requests bypass this entirely — the middleware is a no-op when the
// sealed content type is not present.
//
// Wire format (request, JSON):
//   {
//     "kid": "abcd...",                  // identifies coordinator key (rotation)
//     "ephemeral_public_key": "<b64>",   // sender's ephemeral X25519 public key
//     "ciphertext": "<b64>"              // 24-byte nonce || NaCl Box sealed body
//   }
//
// Wire format (response, JSON, non-streaming):
//   {
//     "kid": "abcd...",
//     "ciphertext": "<b64>"              // sealed using sender's ephemeral pub
//                                        // + coordinator private; nonce prepended
//   }
//
// Wire format (SSE): each event is a single line of the form
//   data: <base64(nonce || sealed_event_bytes)>\n\n
// where the inner bytes are the original SSE event payload (everything between
// the previous `\n\n` boundary and the current one — including the leading
// `data: ` prefix when the upstream emitted one). The client base64-decodes,
// peels off the nonce, NaCl-Box-opens with the coordinator pubkey, and feeds
// the result back into a normal SSE parser.

package api
