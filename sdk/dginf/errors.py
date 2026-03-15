"""Custom exceptions for the DGInf SDK.

Exception hierarchy:
    DGInfError (base)
        AuthenticationError   -- HTTP 401 (invalid/missing API key)
        ProviderUnavailableError -- HTTP 503 (no providers for the model)
        ProviderError         -- HTTP 502 (provider returned an error)
        RequestError          -- Transport-level failures (connection refused, timeout)

All exceptions carry an optional status_code and body for debugging.
The hierarchy lets callers catch specific error types or catch the base
DGInfError for a catch-all handler.
"""

from __future__ import annotations


class DGInfError(Exception):
    """Base exception for all DGInf errors.

    Args:
        message: Human-readable error description.
        status_code: HTTP status code if applicable (None for non-HTTP errors).
        body: Raw response body for debugging.
    """

    def __init__(self, message: str, status_code: int | None = None, body: str | None = None) -> None:
        self.status_code = status_code
        self.body = body
        super().__init__(message)


class AuthenticationError(DGInfError):
    """Raised when the API key is invalid or missing (HTTP 401).

    This typically means the API key was not provided, has been revoked,
    or does not exist in the coordinator's key store.
    """

    def __init__(self, message: str = "Authentication failed — check your API key", body: str | None = None) -> None:
        super().__init__(message, status_code=401, body=body)


class ProviderUnavailableError(DGInfError):
    """Raised when no inference providers are available (HTTP 503).

    This means no connected provider currently serves the requested model.
    The consumer should retry later or try a different model.
    """

    def __init__(
        self, message: str = "No providers available — try again later", body: str | None = None
    ) -> None:
        super().__init__(message, status_code=503, body=body)


class ProviderError(DGInfError):
    """Raised when the upstream provider returned an error (HTTP 502).

    The provider accepted the request but failed during inference (e.g.,
    model not loaded, out of memory, backend crash).
    """

    def __init__(self, message: str = "Provider returned an error", body: str | None = None) -> None:
        super().__init__(message, status_code=502, body=body)


class RequestError(DGInfError):
    """Raised on connection, timeout, or other transport-level errors.

    This wraps httpx transport exceptions (ConnectError, TimeoutException, etc.)
    so callers don't need to import httpx directly.
    """

    def __init__(self, message: str = "Request failed", cause: Exception | None = None) -> None:
        self.__cause__ = cause
        super().__init__(message)
