import sys
sys.dont_write_bytecode = True
from run_tiny_cut import validate_legacy_stderr
import json
base = "[bf16] converted 124 params (0.1 MB) fp16→bf16 in {} ms\n"
for duration in [0, 40, 180000]:
    validate_legacy_stderr(base.format(duration).encode())
valid = base.format(40).encode()
negative = [b"", valid + valid, b"junk\n" + valid, valid + b"junk\n",
    valid.replace(b"124", b"123"), valid.replace(b"0.1 MB", b"0.2 MB"), valid.rstrip(b"\n"),
    *[valid.replace(b"40 ms", value + b" ms") for value in [b"-1", b"1.0", b"040", b"180001", b"1000000"]],
    valid.replace(b" ms", b" s"), valid + b"\x00", valid.replace("→".encode(), b"->"),
    b"[bf16] model.update failed: ignored\n"]
for raw in negative:
    try:
        validate_legacy_stderr(raw)
    except ValueError:
        continue
    raise AssertionError("Invalid stderr was accepted")
print(json.dumps({"accepted": 3, "rejected": len(negative), "nativeExecuted": False}))
