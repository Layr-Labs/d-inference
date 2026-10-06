"""Engine-confirmed token rates/gaps, including simultaneous accepted MTP bursts."""
from collections import defaultdict


def measure(shapes, expected_rows, expected_tokens):
    receipts = shapes.get("confirmedTokenTimings")
    if receipts is None or shapes.get("droppedTokenTimings") != 0:
        return [], [], ["incomplete_token_observation"]
    rows = defaultdict(list)
    last_time = 0
    for receipt in receipts:
        ordinal, count, nanos = (receipt.get(key) for key in ("rowOrdinal", "tokenCount", "relativeNanos"))
        if (type(ordinal) is not int or not 0 <= ordinal < 256 or type(count) is not int or
                not 1 <= count <= 8 or type(nanos) is not int or nanos < last_time):
            return [], [], ["invalid_token_observation"]
        last_time = nanos
        rows[ordinal].append((count, nanos))
    if len(rows) != expected_rows or sum(c for row in rows.values() for c, _ in row) != expected_tokens:
        return [], [], ["token_observation_accounting_mismatch"]
    rates, gaps = [], []
    for row in rows.values():
        total = sum(c for c, _ in row)
        elapsed = row[-1][1] - row[0][1]
        if total > 1 and elapsed > 0:
            rates.append((total - row[0][0]) * 1e9 / elapsed)
        for index, (count, nanos) in enumerate(row):
            if index:
                gaps.append((nanos - row[index - 1][1]) / 1e6)
            # A burst confirms this many tokens at the same existing readback.
            gaps.extend([0.] * (count - 1))
    return rates, gaps, []
