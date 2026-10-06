#!/usr/bin/env python3
"""Print a capped, signup-gated promotion payload; performs no API writes."""
import argparse
from datetime import date, datetime, time, timedelta
import json
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--date", required=True, type=date.fromisoformat, help="First local claim date")
    parser.add_argument("--timezone", required=True, help="IANA zone, e.g. America/Los_Angeles")
    parser.add_argument("--claim-through", type=date.fromisoformat, help="Last local date on which claims are accepted; omit for no time limit")
    parser.add_argument("--signup-cutoff-date", type=date.fromisoformat, help="Last eligible signup date; defaults to --date")
    parser.add_argument("--max-claims", type=int, default=250)
    parser.add_argument("--tokens", type=int, default=150_000_000)
    parser.add_argument("--disabled", action="store_true", help="Stop new claims; existing grants remain usable")
    args = parser.parse_args()
    if not args.model_id.strip() or args.model_id != args.model_id.strip() or len(args.model_id.encode()) > 256:
        parser.error("model-id must be a nonempty identifier of at most 256 bytes")
    if not 1 <= args.tokens <= 1_000_000_000_000:
        parser.error("tokens must be between 1 and 1000000000000")
    if not 1 <= args.max_claims <= 1_000_000:
        parser.error("max-claims must be between 1 and 1000000")
    if args.claim_through and args.claim_through < args.date:
        parser.error("claim-through must not precede date")
    try:
        zone = ZoneInfo(args.timezone)
    except ZoneInfoNotFoundError:
        parser.error("unknown IANA timezone")
    # Construct both midnights in the zone: DST days may be 23 or 25 hours.
    starts = datetime.combine(args.date, time.min, zone)
    ends = datetime.combine(args.claim_through + timedelta(days=1), time.min, zone) if args.claim_through else None
    cutoff = datetime.combine((args.signup_cutoff_date or args.date) + timedelta(days=1), time.min, zone)
    print(json.dumps({"model_id": args.model_id, "tokens": args.tokens,
                      "claim_starts_at": starts.isoformat(), "claim_ends_at": ends.isoformat() if ends else None,
                      "signup_cutoff_at": cutoff.isoformat(), "max_claims": args.max_claims,
                      "enabled": not args.disabled}, indent=2))


if __name__ == "__main__":
    main()
