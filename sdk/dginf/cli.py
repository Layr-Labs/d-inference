"""DGInf CLI — command-line interface for the DGInf consumer SDK.

Provides a terminal-friendly interface for interacting with a DGInf coordinator:
    - ``dginf configure`` — save connection settings
    - ``dginf models`` — list available models with attestation metadata
    - ``dginf ask`` — send a one-shot prompt and stream the response
    - ``dginf chat`` — interactive multi-turn chat session
    - ``dginf deposit`` — credit balance (MVP: ledger-based)
    - ``dginf balance`` — show current balance
    - ``dginf usage`` — show inference usage history with costs

All commands connect to the coordinator over HTTPS/TLS. The coordinator
runs in a GCP Confidential VM, so no client-side encryption is needed.
"""

from __future__ import annotations

import sys
from typing import Optional

import typer
from rich.console import Console
from rich.table import Table

from dginf.client import DGInf
from dginf.config import save_config
from dginf.errors import DGInfError

app = typer.Typer(
    name="dginf",
    help="DGInf — private decentralized AI inference",
    no_args_is_help=True,
)

console = Console()
err_console = Console(stderr=True)


def _get_client() -> DGInf:
    """Build a DGInf client from saved config (or fail with a helpful message).

    Loads connection settings from ~/.dginf/config.toml. If the config
    file is missing or incomplete, prints an error suggesting the user
    run ``dginf configure`` first.
    """
    try:
        return DGInf()
    except DGInfError as exc:
        err_console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code=1) from exc


# ── configure ──────────────────────────────────────────────────────────────


@app.command()
def configure(
    url: str = typer.Option(..., "--url", help="Coordinator base URL"),
    api_key: str = typer.Option(..., "--api-key", help="API key"),
) -> None:
    """Save connection settings to ~/.dginf/config.toml.

    The config file is created with 0600 permissions (owner-only) to
    protect the API key. Subsequent CLI commands and DGInf() client
    instances will load from this file automatically.
    """
    path = save_config(base_url=url, api_key=api_key)
    console.print(f"[green]Config saved to {path}[/green]")


# ── models ─────────────────────────────────────────────────────────────────


@app.command()
def models() -> None:
    """List available models on the coordinator.

    Shows all models currently served by connected providers, including
    model IDs and ownership info. Attestation metadata (trust level,
    Secure Enclave status) is available via the Python SDK.
    """
    client = _get_client()
    try:
        model_list = client.models.list()
    except DGInfError as exc:
        err_console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code=1) from exc
    finally:
        client.close()

    if not model_list.data:
        console.print("[yellow]No models available.[/yellow]")
        return

    table = Table(title="Available Models")
    table.add_column("ID", style="cyan", no_wrap=True)
    table.add_column("Owned By", style="magenta")

    for m in model_list.data:
        table.add_row(m.id, m.owned_by)

    console.print(table)


# ── ask ────────────────────────────────────────────────────────────────────


@app.command()
def ask(
    prompt: str = typer.Argument(..., help="The prompt to send"),
    model: str = typer.Option("qwen3.5-9b", "--model", "-m", help="Model to use"),
) -> None:
    """Send a one-shot prompt and stream the response.

    Sends the prompt as a single user message, streams the assistant's
    response token-by-token to the terminal, and exits.
    """
    client = _get_client()
    try:
        stream = client.chat.completions.create(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            stream=True,
        )
        for chunk in stream:
            if chunk.choices and chunk.choices[0].delta.content:
                console.print(chunk.choices[0].delta.content, end="")
        console.print()  # trailing newline
    except DGInfError as exc:
        err_console.print(f"\n[red]Error:[/red] {exc}")
        raise typer.Exit(code=1) from exc
    finally:
        client.close()


# ── chat ───────────────────────────────────────────────────────────────────


@app.command()
def chat(
    model: str = typer.Option("qwen3.5-9b", "--model", "-m", help="Model to use"),
) -> None:
    """Start an interactive multi-turn chat session.

    Maintains conversation history across turns, sending the full history
    with each request so the model has context. Press Ctrl+C to exit.
    If a request fails, the failed user message is removed from history
    so the conversation state stays clean.
    """
    client = _get_client()
    history: list[dict[str, str]] = []

    console.print("[bold]DGInf Interactive Chat[/bold]  (Ctrl+C to exit)\n")

    try:
        while True:
            try:
                user_input = console.input("[bold cyan]You:[/bold cyan] ")
            except EOFError:
                break

            if not user_input.strip():
                continue

            history.append({"role": "user", "content": user_input})

            console.print("[bold green]AI:[/bold green] ", end="")
            assistant_content = ""

            try:
                stream = client.chat.completions.create(
                    model=model,
                    messages=history,
                    stream=True,
                )
                for chunk in stream:
                    if chunk.choices and chunk.choices[0].delta.content:
                        piece = chunk.choices[0].delta.content
                        console.print(piece, end="")
                        assistant_content += piece
            except DGInfError as exc:
                err_console.print(f"\n[red]Error:[/red] {exc}")
                # Remove the failed user message so the conversation stays clean
                history.pop()
                console.print()
                continue

            console.print()  # trailing newline
            history.append({"role": "assistant", "content": assistant_content})

    except KeyboardInterrupt:
        console.print("\n[dim]Goodbye.[/dim]")
    finally:
        client.close()


# ── deposit ────────────────────────────────────────────────────────────────


@app.command()
def deposit(
    wallet: str = typer.Option(..., "--wallet", help="Ethereum-format wallet address (0x...)"),
    amount: str = typer.Option(..., "--amount", help="Amount in USD (e.g. 10.00)"),
) -> None:
    """Deposit funds to your DGInf balance (MVP: ledger credit).

    In the MVP, this directly credits the internal ledger. In production,
    the coordinator would verify an on-chain pathUSD transfer on the Tempo
    blockchain before crediting the balance.
    """
    client = _get_client()
    try:
        result = client.payments.deposit(wallet_address=wallet, amount_usd=amount)
    except DGInfError as exc:
        err_console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code=1) from exc
    finally:
        client.close()

    console.print(f"[green]Deposited ${amount}[/green]")
    console.print(f"  Wallet: {result.get('wallet_address', wallet)}")
    console.print(f"  Balance: ${float(result.get('balance_micro_usd', 0)) / 1_000_000:.6f}")


# ── balance ───────────────────────────────────────────────────────────────


@app.command()
def balance() -> None:
    """Show your current DGInf balance."""
    client = _get_client()
    try:
        result = client.payments.balance()
    except DGInfError as exc:
        err_console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code=1) from exc
    finally:
        client.close()

    balance_usd = result.get("balance_usd", "0.000000")
    balance_micro = result.get("balance_micro_usd", 0)
    console.print(f"Balance: [bold green]${balance_usd}[/bold green] ({balance_micro} micro-USD)")


# ── usage ─────────────────────────────────────────────────────────────────


@app.command()
def usage() -> None:
    """Show inference usage history with costs.

    Displays a table of past inference requests with model, token counts,
    and cost in USD. Costs are calculated based on output tokens at the
    coordinator's configured rate (default: $0.50 per 1M output tokens).
    """
    client = _get_client()
    try:
        entries = client.payments.usage()
    except DGInfError as exc:
        err_console.print(f"[red]Error:[/red] {exc}")
        raise typer.Exit(code=1) from exc
    finally:
        client.close()

    if not entries:
        console.print("[yellow]No usage recorded yet.[/yellow]")
        return

    table = Table(title="Usage History")
    table.add_column("Job ID", style="dim", no_wrap=True, max_width=12)
    table.add_column("Model", style="cyan")
    table.add_column("Prompt Tokens", justify="right")
    table.add_column("Completion Tokens", justify="right")
    table.add_column("Cost (USD)", justify="right", style="green")

    for entry in entries:
        cost_usd = f"${entry.get('cost_micro_usd', 0) / 1_000_000:.6f}"
        table.add_row(
            entry.get("job_id", "")[:12],
            entry.get("model", ""),
            str(entry.get("prompt_tokens", 0)),
            str(entry.get("completion_tokens", 0)),
            cost_usd,
        )

    console.print(table)


if __name__ == "__main__":
    app()
