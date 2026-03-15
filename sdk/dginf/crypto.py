"""NaCl Box encryption primitives for DGInf.

This module provides X25519 + XSalsa20-Poly1305 (NaCl Box) encryption that is
cross-language compatible with the Rust provider agent's ``crypto_box`` crate.

NOTE: This module is NOT currently used in the client flow. The consumer sends
plain JSON over HTTPS/TLS to the coordinator (which runs in a GCP Confidential
VM with AMD SEV-SNP). The coordinator handles encryption to providers when
needed. This module is kept for potential future use cases such as direct
consumer-to-provider encrypted communication.

The NaCl Box scheme provides:
    - Authenticated encryption (XSalsa20-Poly1305)
    - Key agreement via X25519 Diffie-Hellman
    - Perfect forward secrecy via ephemeral key pairs

Requires: ``PyNaCl >= 1.5``
"""

from __future__ import annotations

import base64

from nacl.public import Box, PrivateKey, PublicKey


class E2ECrypto:
    """NaCl Box encryption with ephemeral key pairs.

    Generates an ephemeral X25519 key pair per session. This can be used
    to encrypt messages to a recipient who holds a long-lived X25519 key
    pair (e.g., a provider's node key).

    The shared secret is derived from the sender's ephemeral private key
    and the recipient's public key (X25519 Diffie-Hellman). The same shared
    secret can be computed by the recipient using their private key and the
    sender's ephemeral public key.

    Usage::

        crypto = E2ECrypto()
        ephemeral_pk_b64, ciphertext = crypto.encrypt_request(
            provider_public_key_b64="...",
            plaintext=b'{"messages": [...]}',
        )
        # ... send ephemeral_pk_b64 + ciphertext to recipient ...
        # ... receive encrypted response ...
        plaintext = crypto.decrypt_response(
            provider_public_key_b64="...",
            ciphertext=response_bytes,
        )
    """

    def __init__(self) -> None:
        # Generate ephemeral key pair for this session. A new key pair per
        # session provides forward secrecy — compromising one session's key
        # does not affect past or future sessions.
        self._private_key = PrivateKey.generate()
        self._public_key = self._private_key.public_key

    @property
    def public_key_base64(self) -> str:
        """Return the ephemeral public key as a base64-encoded string.

        This must be sent alongside the ciphertext so the recipient can
        derive the shared secret for decryption.
        """
        return base64.b64encode(bytes(self._public_key)).decode("ascii")

    def encrypt_request(
        self, provider_public_key_b64: str, plaintext: bytes
    ) -> tuple[str, bytes]:
        """Encrypt a message for a recipient.

        Args:
            provider_public_key_b64: The recipient's X25519 public key,
                base64-encoded (32 bytes decoded).
            plaintext: The message to encrypt.

        Returns:
            A tuple of (ephemeral_public_key_b64, ciphertext).
            The ciphertext is in NaCl Box format (24-byte nonce prepended
            to the encrypted + authenticated data).
        """
        provider_pk = PublicKey(base64.b64decode(provider_public_key_b64))
        box = Box(self._private_key, provider_pk)
        ciphertext = box.encrypt(plaintext)
        return self.public_key_base64, bytes(ciphertext)

    def decrypt_response(
        self, provider_public_key_b64: str, ciphertext: bytes
    ) -> bytes:
        """Decrypt a message from the recipient.

        Uses the same shared secret (derived from our ephemeral private key
        and the recipient's public key) to decrypt the response.

        Args:
            provider_public_key_b64: The recipient's X25519 public key,
                base64-encoded.
            ciphertext: The encrypted response in NaCl Box format
                (24-byte nonce || encrypted data).

        Returns:
            The decrypted plaintext response.

        Raises:
            nacl.exceptions.CryptoError: If decryption fails (wrong key,
                tampered data, etc.).
        """
        provider_pk = PublicKey(base64.b64decode(provider_public_key_b64))
        box = Box(self._private_key, provider_pk)
        return box.decrypt(ciphertext)
