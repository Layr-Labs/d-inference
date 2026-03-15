"""DGInf SDK — Python client for the DGInf decentralized inference platform.

This package provides an OpenAI-compatible client for sending inference requests
to the DGInf coordinator. The coordinator runs in a GCP Confidential VM (AMD
SEV-SNP), so consumer traffic arrives over standard HTTPS/TLS without needing
client-side encryption.

Architecture overview:
    Consumer (this SDK) --HTTPS/TLS--> Coordinator (Confidential VM)
        --> Provider (attested Apple Silicon Mac)

The coordinator handles routing, provider attestation verification, payment
ledger management, and (optionally) encrypting requests to providers. The
consumer does not need to handle any encryption.

Exports:
    DGInf           -- Main client class (drop-in replacement for OpenAI client)
    E2ECrypto       -- NaCl Box crypto primitives (kept for future use, not used in client)
    DGInfError      -- Base exception for all SDK errors
    AuthenticationError     -- Raised on HTTP 401
    ProviderUnavailableError -- Raised on HTTP 503
    ProviderError   -- Raised on HTTP 502
    RequestError    -- Raised on transport-level failures
"""

from dginf.client import DGInf
from dginf.crypto import E2ECrypto
from dginf.errors import (
    DGInfError,
    AuthenticationError,
    ProviderUnavailableError,
    ProviderError,
    RequestError,
)

__version__ = "0.1.0"
__all__ = [
    "DGInf",
    "E2ECrypto",
    "DGInfError",
    "AuthenticationError",
    "ProviderUnavailableError",
    "ProviderError",
    "RequestError",
]
