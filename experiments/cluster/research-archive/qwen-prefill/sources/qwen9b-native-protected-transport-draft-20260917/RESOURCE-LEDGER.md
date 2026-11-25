# Closed operational allowance

Scope: registered 9B, cut16, serial prefill, P32/C16/O2, empty stops, BF16 residuals. Ordinary quota 16, <=300-second lifetime, state formulas, tensor math and 6/4/2 GiB policies remain unchanged. Lookahead and every other workload refuse in this experiment, including recording SPI selection.

Each native process permits one synchronous protected operation across both directions, all setup/control/request views and one codec. There is no separately concurrent receive or control channel. The other rank may perform its matching operation concurrently in its own process. The original P2P completion fence owns input/output handles until completed native work; immutable lookahead tickets remain available in the shared facade, but this first profile does not admit lookahead.

Per rank the additional charge is **186,302,720 bytes**:

| Term | Bytes | Lifetime / evidence |
| --- | ---: | --- |
| Full measured physical increment | 71,532,640 | Larger complete two-endpoint mailbox peak from the 35-case runs; never halved and no native amount subtracted |
| All mesh/scatter backing | 12,533,760 | `4096 * (1+…+128) * 2 slots * (2 mesh+4 scatter)`; includes unused scatter slots; backend may retain it until process exit |
| Four maximum logical host copies | 524,448 | `4 * (131072+40)`; source Data, sealed/received record and codec body copies remain charged conservatively |
| Key/public metadata allowance | 1,048,576 | Authority, contexts, transcript and bounded metadata through retirement/invalidation |
| Additional operational safety | 67,108,864 | Foundation/CryptoKit/verbs/page/allocator overhead; a policy allowance, not a proven peak |
| Separate native allowance | 33,554,432 | Complete observed 20,987,904-byte native peak plus actual bounds for a maximum plaintext and frame allocation and metadata allowance must fit; charged in addition to the full physical term |

The real load gate adds both host/native amounts to remaining selected tensor/host overlap and the native amount to allocator requirements. Ready adds their sum to the ordinary maximum request allowance. Reserve checks complete owner capacity before request state; start/live checks retain the same charge with prefill/capture extras until retirement. Native cache is zero. Hardware is closed to `Mac16,7`, physical 24/48 GiB and OS `26A428`, matching the retained observations. The descriptor binds source/evidence identities and calls this an experiment, not a general serving floor or proof of a whole-process peak.

At most two backend work requests use send/receive scratch during one blocking point-to-point call. Posted SGE sizes and receive lengths are unchanged; the exact tail V2 sources clear the complete unused posted region. Logical record = plaintext + 40 bytes; this is one adapter/native P2P call, not necessarily one RDMA WQE. For the 131,112-byte maximum, backend frame segmentation can post two scratch frames. Their complete backing was charged above; no stale plaintext tail is permitted.

Setup reserves two 256-byte records per direction (load agreement and loaded readiness). Each request reserves **29 records / 461,852 plaintext bytes per direction**, conservatively counting both ranks' traffic classes: request readiness, three residual headers/payloads, all ready/consumed ACKs, two token and decision packets/ACKs, and retirement ACK. The unchanged 16-request quota needs 466 records / 7,390,144 bytes per direction, below fixed 1,024 / 16,777,216 limits. Credit is reserved in the existing serialized owner, never refunded after failure, and checked against actual codec counters before every export/open. One authority-created transport owns strict sequence counters globally; views never restart or duplicate them.

The allocation reviews `14e970b0…91fe` and `73be77f1…59d0` explicitly remain `profileQualified=false`, `rdmaMeasured=false`, `servingEnabled=false`. They measure two codec endpoints/native staging in a process with an in-memory ciphertext mailbox. The new RDMA/authority overhead is derived plus operational safety and must be observed during the first protected pair run. There is no claim that these receipts already measured a protected RDMA workload. The native process lease is not reopened after protected shutdown because a cached backend may retain its bootstrap; the enclosing real child must exit before the next protected native session.
