"""Tests for dginf.crypto — E2E encryption for inference requests."""

from __future__ import annotations

import base64

import pytest

from dginf.crypto import E2ECrypto


def test_generate_keys() -> None:
    """E2ECrypto generates a valid key pair."""
    crypto = E2ECrypto()
    pk_b64 = crypto.public_key_base64
    assert len(pk_b64) > 0

    # Base64 of 32 bytes should be 44 characters (with padding)
    pk_bytes = base64.b64decode(pk_b64)
    assert len(pk_bytes) == 32


def test_different_sessions_have_different_keys() -> None:
    """Each E2ECrypto instance generates unique ephemeral keys."""
    c1 = E2ECrypto()
    c2 = E2ECrypto()
    assert c1.public_key_base64 != c2.public_key_base64


def test_encrypt_decrypt_round_trip() -> None:
    """Encrypt with one key pair, decrypt with the other — basic NaCl Box."""
    # Simulate a consumer and provider
    consumer = E2ECrypto()
    provider = E2ECrypto()

    plaintext = b"Hello, encrypted world!"

    # Consumer encrypts for provider
    _, ciphertext = consumer.encrypt_request(
        provider.public_key_base64, plaintext
    )

    # Provider decrypts
    decrypted = provider.decrypt_response(
        consumer.public_key_base64, ciphertext
    )

    assert decrypted == plaintext


def test_encrypt_decrypt_response_round_trip() -> None:
    """Provider encrypts response, consumer decrypts it."""
    consumer = E2ECrypto()
    provider = E2ECrypto()

    response_data = b'{"choices": [{"message": {"content": "Hello!"}}]}'

    # Provider encrypts response for consumer
    _, ciphertext = provider.encrypt_request(
        consumer.public_key_base64, response_data
    )

    # Consumer decrypts
    decrypted = consumer.decrypt_response(
        provider.public_key_base64, ciphertext
    )

    assert decrypted == response_data


def test_wrong_key_fails_to_decrypt() -> None:
    """Decryption with the wrong key raises an error."""
    consumer = E2ECrypto()
    provider = E2ECrypto()
    wrong_key = E2ECrypto()

    plaintext = b"Secret message"

    # Consumer encrypts for provider
    _, ciphertext = consumer.encrypt_request(
        provider.public_key_base64, plaintext
    )

    # Trying to decrypt with wrong key should fail
    with pytest.raises(Exception):
        wrong_key.decrypt_response(consumer.public_key_base64, ciphertext)


def test_encrypt_empty_plaintext() -> None:
    """Encrypting and decrypting empty data works."""
    consumer = E2ECrypto()
    provider = E2ECrypto()

    _, ciphertext = consumer.encrypt_request(
        provider.public_key_base64, b""
    )

    decrypted = provider.decrypt_response(
        consumer.public_key_base64, ciphertext
    )

    assert decrypted == b""


def test_encrypt_large_payload() -> None:
    """Encrypting and decrypting a large payload works."""
    consumer = E2ECrypto()
    provider = E2ECrypto()

    plaintext = bytes(range(256)) * 100  # 25.6 KB

    _, ciphertext = consumer.encrypt_request(
        provider.public_key_base64, plaintext
    )

    decrypted = provider.decrypt_response(
        consumer.public_key_base64, ciphertext
    )

    assert decrypted == plaintext


def test_different_encryptions_produce_different_ciphertext() -> None:
    """Encrypting the same plaintext twice produces different ciphertext (random nonces)."""
    consumer = E2ECrypto()
    provider = E2ECrypto()

    plaintext = b"Same message"

    _, ct1 = consumer.encrypt_request(provider.public_key_base64, plaintext)
    _, ct2 = consumer.encrypt_request(provider.public_key_base64, plaintext)

    assert ct1 != ct2

    # Both should decrypt correctly
    d1 = provider.decrypt_response(consumer.public_key_base64, ct1)
    d2 = provider.decrypt_response(consumer.public_key_base64, ct2)
    assert d1 == plaintext
    assert d2 == plaintext


def test_ciphertext_format_nacl_box() -> None:
    """Ciphertext should be in NaCl Box format: 24-byte nonce + encrypted data."""
    consumer = E2ECrypto()
    provider = E2ECrypto()

    plaintext = b"test"

    _, ciphertext = consumer.encrypt_request(
        provider.public_key_base64, plaintext
    )

    # NaCl Box format: 24-byte nonce + 16-byte MAC + plaintext
    assert len(ciphertext) >= 24 + 16 + len(plaintext)
