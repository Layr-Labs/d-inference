# 2026-09-15: local distributed quota rotation

The private implementation passed 90 Provider tests in 13 suites and five actual local HTTP/owner-child scenarios. It can retain one listener and discovery record across normal session request-quota exhaustion when the caller supplies a replacement-session factory. The exact tested promotion is ready for review; MAIN and the installed product have not been changed.

Each generation owns its session, bridge, response registry and acquisitions. At quota exhaustion the host closes that generation's admissions, starts its drain, waits for its response/acquisition holds and bridge shutdown, and requires native cleanup, authenticated owner release ACKs and clean owner transport termination. Only then may it prepare and start a replacement. The replacement must retain the initial installed binding/model/profile and use an epoch never seen by this host. Old response tickets and callbacks cannot attach to the replacement. The HTTP listener and its discovery record remain in place during the unavailable interval.

| Check | Observed result |
| --- | --- |
| Normal quota rotation | 33 completed HTTP requests across three fresh epochs; two quota boundaries; one bound listener and one discovery publication; all six owner endpoints released cleanly. |
| Held acquisition and response | The replacement factory remained blocked until both old holds ended; the canonical lease inode was reused only after the release barrier. |
| Missing release ACK | Actual native cleanup and owner exit did not permit replacement; the host retained quarantine. |
| Nonzero owner exit | An observed release ACK did not permit replacement when the owner exited nonzero; quarantine remained. |
| Stop during replacement startup | The started owner remained retained and was cleaned; the late second owner was not launched and no replacement was published. |
| Repository regressions | 90 tests passed, including stale generation callbacks/tickets, ABA epoch reuse, changed installed binding, already-started factory output, late factory completion, fixed lifetime and no-factory behavior. |

The Provider test process took 117.635 seconds, including compilation; the test runner reported 1.052 seconds for the 90 tests. The five actual-child scenarios took 7.832 seconds after the final fixture-only rebuild. Each driver was reaped with its process group absent. The private candidate's 13,780 source/dependency pins and MAIN's 13,766 pins remained unchanged through qualification.

Two failed attempts are retained. First, the private executable required a test-only import to access the existing internal endpoint constructor. Second, a fixture tried to acquire the canonical lock after the replacement owner was already Ready. The corrected assertion separates the old endpoint's release proof from the empty/unlocked check, which still runs before every replacement and after final clean shutdown. Neither correction changed production source or relaxed the replacement barrier.

The proposed promotion contains 14 runtime files and two repository test files: eight replacements and eight additions. It excludes the private executable, fixture children, Python runners and Package.swift changes. `promotion.json` pins current MAIN preimages and the exact tested after-bytes; `runtime-and-tests.patch` is the full source diff; `validation.json` binds the receipts and preserved failures.

This is the first quota-only slice. The default nil factory preserves the existing one-session behavior, and the current CLI still uses that default. Fixed lifetime expiry continues to stop the host; limits are unchanged. No model weights, GPU computation, remote owners or physical multi-Mac rotation were exercised, and these durations are not inference-performance measurements. Trusted coordinator-verified/routable membership and atomic reservation of both devices' capacity remain separate work.
