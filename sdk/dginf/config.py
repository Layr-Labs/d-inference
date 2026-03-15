"""Config file management for DGInf (~/.dginf/config.toml).

Stores and loads connection settings (coordinator URL and API key) from a
TOML file in the user's home directory. The config file is created with
restrictive permissions (0600) to protect the API key.

The config file format is minimal::

    base_url = "https://coordinator.dginf.io"
    api_key = "dginf-abcdef..."

Both the DGInf client class and the CLI load from this file as a fallback
when connection parameters are not provided directly.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

import tomli_w

if sys.version_info >= (3, 11):
    import tomllib
else:
    import tomli as tomllib


_CONFIG_DIR = Path.home() / ".dginf"
_CONFIG_FILE = _CONFIG_DIR / "config.toml"


def config_path() -> Path:
    """Return the path to the config file (~/.dginf/config.toml)."""
    return _CONFIG_FILE


def load_config(path: Path | None = None) -> dict[str, Any] | None:
    """Load the config file and return its contents, or None if it doesn't exist.

    Args:
        path: Override the default config file path (used in tests).

    Returns:
        A dict with "base_url" and "api_key" keys, or None if the file
        does not exist.
    """
    p = path or _CONFIG_FILE
    if not p.exists():
        return None
    with open(p, "rb") as f:
        return tomllib.load(f)


def save_config(
    base_url: str,
    api_key: str,
    path: Path | None = None,
) -> Path:
    """Save config to ~/.dginf/config.toml (or a custom path).

    Creates the parent directory if it doesn't exist. Sets file permissions
    to 0600 (owner read/write only) on Unix systems to protect the API key.

    Args:
        base_url: Coordinator URL to save.
        api_key: API key to save.
        path: Override the default config file path (used in tests).

    Returns:
        The path to the saved config file.
    """
    p = path or _CONFIG_FILE
    p.parent.mkdir(parents=True, exist_ok=True)

    data: dict[str, Any] = {"base_url": base_url, "api_key": api_key}

    with open(p, "wb") as f:
        tomli_w.dump(data, f)

    # Restrict permissions to owner-only on Unix to protect the API key
    try:
        os.chmod(p, 0o600)
    except OSError:
        pass

    return p
