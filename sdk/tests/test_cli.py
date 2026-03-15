"""Smoke tests for the DGInf CLI — verify commands are registered."""

from __future__ import annotations

from typer.testing import CliRunner

from dginf.cli import app

runner = CliRunner()


def test_help() -> None:
    result = runner.invoke(app, ["--help"])
    assert result.exit_code == 0
    assert "DGInf" in result.output


def test_configure_help() -> None:
    result = runner.invoke(app, ["configure", "--help"])
    assert result.exit_code == 0
    assert "--url" in result.output
    assert "--api-key" in result.output


def test_models_help() -> None:
    result = runner.invoke(app, ["models", "--help"])
    assert result.exit_code == 0


def test_ask_help() -> None:
    result = runner.invoke(app, ["ask", "--help"])
    assert result.exit_code == 0
    assert "--model" in result.output


def test_chat_help() -> None:
    result = runner.invoke(app, ["chat", "--help"])
    assert result.exit_code == 0
    assert "--model" in result.output


def test_deposit_help() -> None:
    result = runner.invoke(app, ["deposit", "--help"])
    assert result.exit_code == 0
    assert "--wallet" in result.output
    assert "--amount" in result.output


def test_balance_help() -> None:
    result = runner.invoke(app, ["balance", "--help"])
    assert result.exit_code == 0


def test_usage_help() -> None:
    result = runner.invoke(app, ["usage", "--help"])
    assert result.exit_code == 0
