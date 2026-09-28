# Native RDMA send-buffer checks

These CPU checks compile the current JACCL mesh, ring and RDMA headers with
AddressSanitizer and UndefinedBehaviorSanitizer. Allocation, registration and
verbs are simulated; native staging, posted lengths and completion handling run
from the actual headers. No GPU, model, peer or network connection is used.

Run from the repository root with a new output directory:

```sh
python3 -B libs/darkbloom-cluster/Tests/NativeSendChecks/run.py --output /tmp/darkbloom-send-checks
```

Sentinel-filled scratch storage detects stale bytes in partial frames. The fake
verbs endpoint copies the entire posted frame and requires send storage to remain
unchanged until its completion is polled. Cases cover typed and zero-length
logical staging, P2P reuse, multiple frames, one/two-wire rings, gather, reduction
and scatter. Valid payload, zero padding, output guards and drained completion
queues must all match.

`OriginalHeaders` retains the five upstream headers used to reproduce the
original stale-tail bug. A separate executable must observe that specific
failure. They are test fixtures and are never selected by the native build.

The runner uses the bounded child-process helper from `SecurityChecks`, retaining
source identities, logs and cleanup receipts. Compiler and executable bounds are
60 and 10 seconds respectively. Hardware compatibility and encryption require
separate checks on the two actual Macs.
