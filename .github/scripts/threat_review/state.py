"""Persistent review budget state. Contents SHA compare-and-swap serializes all spend.

The dedicated branch must be initialized by a maintainer. A missing ledger,
permission failure, conflict exhaustion or uncertain write never permits spend.
No Actions cache, PR-controlled ref, automatic reset, or expiring reservation.
"""
import base64
import copy
import json
import re
from datetime import datetime, timezone
from uuid import uuid4
from .client import APIError, ReviewUnavailable

BRANCH = "codex/threat-review-state"
MAX_STATE_BYTES = 500_000
USD = 1_000_000  # integer microdollars, rounded up at reservation boundaries
CAPS = {"normal": USD, "deep": 3 * USD, "pr_day": 5 * USD,
        "repo_day": 25 * USD, "pilot": 25 * USD, "prs": 10}


class BudgetStopped(ReviewUnavailable):
    """Safe fixed reason, never an upstream error body."""


def fresh():
    return {"version": 1, "halted": False, "prs": [], "requests": {}}


class State:
    def __init__(self, github, budget_mode="pilot"):
        if budget_mode not in ("pilot", "daily"):
            raise BudgetStopped("Invalid review budget mode; expected pilot or daily")
        self.github = github
        self.budget_mode = budget_mode

    def read(self, path):
        try:
            result = self.github.call(f"/contents/{path}?ref={BRANCH}")
        except APIError as error:
            if error.status == 404:
                return None, None
            raise
        if result.get("encoding") != "base64" or result.get("size", MAX_STATE_BYTES + 1) > MAX_STATE_BYTES:
            raise ReviewUnavailable("Review state exceeds capacity")
        raw = base64.b64decode(result["content"], validate=False)
        if len(raw) > MAX_STATE_BYTES:
            raise ReviewUnavailable("Review state exceeds capacity")
        return json.loads(raw), result["sha"]

    def write(self, path, value, sha=None):
        raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        if len(raw) > MAX_STATE_BYTES:
            raise ReviewUnavailable("Review state exceeds capacity")
        body = {"branch": BRANCH, "message": "chore: checkpoint advisory review state [skip ci]",
                "content": base64.b64encode(raw).decode()}
        if sha:
            body["sha"] = sha
        return self.github.call(f"/contents/{path}", body, "PUT")

    def read_ledger(self):
        ledger, sha = self.read("ledger.json")
        if (not sha or not isinstance(ledger, dict) or ledger.get("version") != 1
                or type(ledger.get("halted")) is not bool
                or not isinstance(ledger.get("requests"), dict)
                or not isinstance(ledger.get("prs"), list)):
            raise BudgetStopped("Budget ledger is not initialized or is invalid; no paid request allowed")
        return ledger, sha

    def mutate(self, update):
        for _ in range(8):
            ledger, sha = self.read_ledger()
            result = update(ledger)
            try:
                self.write("ledger.json", ledger, sha)
                return result
            except APIError as error:
                if error.status != 409:
                    raise
        raise BudgetStopped("Concurrent budget updates did not settle; no paid request allowed")

    def check_reservation(self, ledger, pr, run, tier, amount, day):
        if ledger["halted"]:
            raise BudgetStopped("Budget circuit breaker is open; maintainer investigation required")
        rows = list(ledger["requests"].values())
        # Validate every row before arithmetic; never default missing cost to zero.
        for row in rows:
            if (not isinstance(row, dict) or type(row.get("charge")) is not int
                    or row["charge"] < 0 or type(row.get("settled")) is not bool
                    or not all(k in row for k in ("day", "pr", "run", "tier"))):
                raise BudgetStopped("Invalid budget ledger; no paid request allowed")
        if len(rows) >= 1000:
            raise BudgetStopped("Review ledger request capacity reached; maintainer maintenance required")
        if self.budget_mode == "pilot" and pr not in ledger["prs"] and len(ledger["prs"]) >= CAPS["prs"]:
            raise BudgetStopped("Ten-PR pilot complete; maintainer evaluation required")
        checks = [
            ("repo_day", [r for r in rows if r["day"] == day or not r["settled"]]),
            ("pr_day", [r for r in rows if r["pr"] == pr and (r["day"] == day or not r["settled"])]),
            (tier, [r for r in rows if r["run"] == run and r["tier"] == tier]),
        ]
        if self.budget_mode == "pilot":
            checks.insert(0, ("pilot", rows))
        for name, selected in checks:
            if sum(r["charge"] for r in selected) + amount > CAPS[name]:
                raise BudgetStopped(f"{name} spending limit reached; remaining coverage deferred")

    def check_capacity(self):
        """Read-only snapshot: a new PR must have room for a normal attempt.

        This does not reserve funds or guarantee a later request. Every actual
        reservation still rechecks caps atomically, including unknown charges.
        """
        ledger, _ = self.read_ledger()
        self.check_reservation(ledger, None, None, "normal", CAPS["normal"],
                               datetime.now(timezone.utc).date().isoformat())

    def reserve(self, pr, run, tier, amount, now=None):
        if tier not in ("normal", "deep") or type(amount) is not int or amount <= 0:
            raise BudgetStopped("Invalid cost reservation")
        day = (now or datetime.now(timezone.utc)).date().isoformat()
        ticket = uuid4().hex
        def update(ledger):
            self.check_reservation(ledger, pr, run, tier, amount, day)
            if pr not in ledger["prs"]:
                ledger["prs"].append(pr)
            ledger["requests"][ticket] = {"pr": pr, "run": run, "tier": tier, "day": day,
                                           "charge": amount, "reserved": amount, "settled": False}
            return ticket
        return self.mutate(update)

    def admit(self, pr):
        """Record PR admission; the default pilot also counts cache-only reviews."""
        def update(ledger):
            if pr not in ledger["prs"]:
                if self.budget_mode == "pilot" and len(ledger["prs"]) >= CAPS["prs"]:
                    raise BudgetStopped("Ten-PR pilot complete; maintainer evaluation required")
                ledger["prs"].append(pr)
        self.mutate(update)

    def settle(self, ticket, actual):
        if type(actual) is not int or actual < 0:
            raise BudgetStopped("Invalid provider usage; reservation retained")
        def update(ledger):
            row = ledger["requests"][ticket]
            if row["settled"]:
                if row["charge"] != actual:
                    raise BudgetStopped("Conflicting usage reconciliation")
                return
            row.update(charge=actual, settled=True)
            if actual > row["reserved"]:
                ledger["halted"] = True
        self.mutate(update)

    def cached(self, fingerprint):
        if not re.fullmatch(r"[a-f0-9]{64}", fingerprint):
            raise ReviewUnavailable("Invalid cache key")
        return self.read(f"cache/{fingerprint}.json")[0]

    def save_cache(self, fingerprint, value):
        try:
            self.write(f"cache/{fingerprint}.json", value)
        except APIError as error:
            # Immutable cache: another identical request may have won the race.
            if error.status not in (409, 422) or self.cached(fingerprint) is None:
                raise

    def checkpoint(self, run, value):
        if not re.fullmatch(r"[0-9]+-[0-9]+", run):
            raise ReviewUnavailable("Invalid run identity")
        path = f"reports/{run}.json"
        _, sha = self.read(path)
        result = self.write(path, copy.deepcopy(value), sha)
        # Immutable commit URL preserves each checkpoint even after another write.
        repo = self.github.root.replace("https://api.github.com/repos/", "https://github.com/")
        return f"{repo}/blob/{result['commit']['sha']}/{path}"


def initialize(github, base):
    """Explicit maintainer-only CLI operation; never called by a PR scan."""
    if not re.fullmatch(r"[a-f0-9]{40}", base):
        raise ReviewUnavailable("Initialization requires a full trusted base SHA")
    state = State(github)
    try:
        github.call("/git/refs", {"ref": f"refs/heads/{BRANCH}", "sha": base}, "POST")
    except APIError as error:
        if error.status != 422:
            raise
        github.call(f"/git/ref/heads/{BRANCH}")
    value, _ = state.read("ledger.json")
    if value is not None:
        raise ReviewUnavailable("Ledger already exists; initialization never resets spending")
    state.write("ledger.json", fresh())
