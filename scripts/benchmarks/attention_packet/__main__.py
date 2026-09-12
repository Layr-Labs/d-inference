"""Run: python -m attention_packet PACKET_JSON --output NEW_REPORT_JSON."""

import argparse
import json
from pathlib import Path

from .files import PacketError, UnsupportedPacket
from .packet import load_packet
from .reference import analyze


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packet")
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        report = analyze(load_packet(args.packet))
        code = 0
    except UnsupportedPacket as error:
        report, code = {"schema": "darkbloom.attention-analysis.v1", "status": "inconclusive", "error": str(error)}, 2
    except (PacketError, OSError) as error:
        report, code = {"schema": "darkbloom.attention-analysis.v1", "status": "refused", "error": str(error)}, 2
    # Never overwrite captured input or an earlier analysis artifact.
    with Path(args.output).open("x") as destination:
        json.dump(report, destination, indent=2, allow_nan=False)
        destination.write("\n")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
