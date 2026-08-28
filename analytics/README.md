# Darkbloom local analytics

This directory contains the short-lived, downstream analytics process. It is
separate from the Swift inference provider and is the only component that uses
DuckDB.

## Local setup

Enable the provider's privacy-safe terminal events in `provider.toml`:

```toml
[analytics]
enabled = true
```

Install the processor in an isolated environment and initialize the workspace:

```bash
cd analytics
python3 -m venv .venv
.venv/bin/pip install -e .
.venv/bin/darkbloom-analytics init
```

Run one conversion pass:

```bash
.venv/bin/darkbloom-analytics run
```

The command is intentionally short-lived. `init` generates a five-minute,
background-priority launchd definition at:

```text
~/.darkbloom/analytics/launchd/dev.darkbloom.analytics.plist
```

Install it when you are ready to schedule processing:

```bash
cp ~/.darkbloom/analytics/launchd/dev.darkbloom.analytics.plist \
  ~/Library/LaunchAgents/dev.darkbloom.analytics.plist
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/dev.darkbloom.analytics.plist
```

A missed invocation is harmless; the next run discovers all eligible completed
UTC hours and processing is idempotent.

Start Rill against the installed project after installing the Rill CLI:

```bash
rill start ~/.darkbloom/analytics/rill
```

The Rill `jobs_all` model unions completed job Parquet with finalized recent
NDJSON using `processor-state.json` as a mutually exclusive watermark.

## Retention defaults

- Finalized NDJSON: 3 days
- Job-level Parquet: 90 days
- Hourly rollups: retained

The provider never deletes normal analytics history. Retention, validation,
quarantine, Parquet generation, and Rill files all belong to this module.

## Test

```bash
.venv/bin/python -m unittest discover -s tests -v
```
