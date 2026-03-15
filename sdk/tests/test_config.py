"""Tests for dginf.config — config file management."""

from __future__ import annotations

from pathlib import Path

from dginf.config import load_config, save_config


def test_save_and_load(tmp_path: Path) -> None:
    config_file = tmp_path / "config.toml"

    save_config(base_url="http://localhost:8080", api_key="sk-test-123", path=config_file)

    assert config_file.exists()

    cfg = load_config(path=config_file)
    assert cfg is not None
    assert cfg["base_url"] == "http://localhost:8080"
    assert cfg["api_key"] == "sk-test-123"


def test_load_missing_file(tmp_path: Path) -> None:
    result = load_config(path=tmp_path / "nonexistent.toml")
    assert result is None


def test_save_creates_parent_dirs(tmp_path: Path) -> None:
    config_file = tmp_path / "deep" / "nested" / "config.toml"

    save_config(base_url="http://x", api_key="k", path=config_file)

    assert config_file.exists()
    cfg = load_config(path=config_file)
    assert cfg is not None
    assert cfg["base_url"] == "http://x"


def test_save_overwrites(tmp_path: Path) -> None:
    config_file = tmp_path / "config.toml"

    save_config(base_url="http://first", api_key="key1", path=config_file)
    save_config(base_url="http://second", api_key="key2", path=config_file)

    cfg = load_config(path=config_file)
    assert cfg is not None
    assert cfg["base_url"] == "http://second"
    assert cfg["api_key"] == "key2"
