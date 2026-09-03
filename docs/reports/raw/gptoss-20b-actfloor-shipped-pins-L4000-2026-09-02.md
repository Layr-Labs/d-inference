# BenchCBv2RealModel report

| | |
|---|---|
| Model | ~/.cache/huggingface/hub/models--mlx-community--gpt-oss-20b-MXFP4-Q8/snapshots/773a7da77e569019bb0fd17a554b263738d669a3 |
| Label | actfloor-shipped-pins-L4000 |
| Profile | stock |
| Prefill construction | chunk=512, soloStripe=off |
| Chip | Apple M4 Max |
| RAM | 128 GB |
| OS | Version 26.5.2 (Build 25F84) |
| Host at start | load avg (1m) 10.2 / 16 cores; DARKBLOOM RUNNING — **HOST CONTENDED, numbers suspect** |
| Invocation | `.build/release/BenchCBv2 --model ~/.cache/huggingface/hub/models--mlx-community--gpt-oss-20b-MXFP4-Q8/snapshots/773a7da77e569019bb0fd17a554b263738d669a3 --mode perf --engines v2 --batches 8 --prompt-lengths 4000 --max-seq-len 8000 --steps 64 --label actfloor-shipped-pins-L4000 --out ~/Documents/Builds/d-inference/.worktrees/activation-reserve-overhaul/docs/reports/raw/gptoss-20b-actfloor-shipped-pins-L4000-2026-09-02.md` |
| Prompt lengths | 4000 |
| Paged nominalMaxSeqLen | 8000 |
| mlx-swift-lm (build) | 30da946 |
| Date | 2026-09-02T23:43:58Z |

model class: GPTOSSModel; layers: 24
- optimization model: layer18(requested=false, effective=false, interval=n/a); weightedUnsort(requested=false, effective=false); safeR1GeometryEligible=false; safeR1(requested=false, effective=false, aot=false, nax=false)
- optimization-run-json: {"model":{"layer18Effective":false,"layer18Requested":false,"safeR1GeometryEligible":false,"weightedUnsortEffective":false,"weightedUnsortRequested":false},"safeR1AOTAvailable":false,"safeR1Effective":false,"safeR1NAXAvailable":false,"safeR1Requested":false}
vocabSize=201088

## Performance (maxTokens 64)

| engine | B | prompts (tok) | decode TPS/req | agg TPS | TTFT p50 (ms) | ITL p50 (ms) |
|---|---|---|---|---|---|---|
| v2 | 8 | 4000/4000/4000/4000/4000/4000/4000/4000 | 3.1 | 4.8 | 71901 | 209.5 |

- optimization provenance [perf/v2/B8]: layer18(requested=false, effective=false, interval=n/a); weightedUnsort(requested=false, effective=false); safeR1GeometryEligible=false; layer18ExpectedMinimumSubmissions=0, layer18Submissions=0, layer18Engaged=false; weightedCalls=0, weightedEngaged=false; safeR1(requested=false, effective=false, armed=true, aot=false, nax=false, exactGeometryExpected=false, attempts=0, hits=0, fallbacks=0, fallbackNAX=0, fallbackOuterRoute=0, fallbackQuantization=0, fallbackTopology=0, fallbackAssignmentCount=0, fallbackGeometry=0, fallbackMetallibUnavailable=0)
- optimization-cell-json [perf/v2/B8]: {"aggregateTPS":4.791986334708455,"batch":8,"decodeTPSPerRequest":3.125774764601199,"engine":"v2","itlP50Ms":209.5245122909546,"optimizationProvenance":{"layer18Engaged":false,"layer18ExpectedMinimumSubmissions":0,"layer18IntermediateSubmissions":0,"model":{"layer18Effective":false,"layer18Requested":false,"safeR1GeometryEligible":false,"weightedUnsortEffective":false,"weightedUnsortRequested":false},"safeR1":{"aotAvailable":false,"armed":true,"attempts":0,"effective":false,"exactGeometryExpected":false,"fallbackAssignmentCount":0,"fallbackGeometry":0,"fallbackMetallibUnavailable":0,"fallbackNAX":0,"fallbackOuterRoute":0,"fallbackQuantization":0,"fallbackTopology":0,"fallbacks":0,"hits":0,"naxAvailable":false,"requested":false},"weightedUnsortEffectiveCalls":0,"weightedUnsortEngaged":false},"perRequest":["    req 0: prompt=4000 tokens=64 ttft=49217ms decodeTPS=1.1 finish=length","    req 1: prompt=4000 tokens=64 ttft=49217ms decodeTPS=1.1 finish=length","    req 2: prompt=4000 tokens=64 ttft=49217ms decodeTPS=1.1 finish=length","    req 3: prompt=4000 tokens=64 ttft=49217ms decodeTPS=1.1 finish=length","    req 4: prompt=4000 tokens=64 ttft=94584ms decodeTPS=5.1 finish=length","    req 5: prompt=4000 tokens=64 ttft=94584ms decodeTPS=5.1 finish=length","    req 6: prompt=4000 tokens=64 ttft=94584ms decodeTPS=5.1 finish=length","    req 7: prompt=4000 tokens=64 ttft=94584ms decodeTPS=5.1 finish=length"],"promptMix":[4000,4000,4000,4000,4000,4000,4000,4000],"ttftP50Ms":71900.57694911957}

Per-request detail:
    [mem after v2 B=8] gpuActive=11.25 GiB gpuPeak=15.42 GiB
  v2 B=8:
    req 0: prompt=4000 tokens=64 ttft=49217ms decodeTPS=1.1 finish=length
    req 1: prompt=4000 tokens=64 ttft=49217ms decodeTPS=1.1 finish=length
    req 2: prompt=4000 tokens=64 ttft=49217ms decodeTPS=1.1 finish=length
    req 3: prompt=4000 tokens=64 ttft=49217ms decodeTPS=1.1 finish=length
    req 4: prompt=4000 tokens=64 ttft=94584ms decodeTPS=5.1 finish=length
    req 5: prompt=4000 tokens=64 ttft=94584ms decodeTPS=5.1 finish=length
    req 6: prompt=4000 tokens=64 ttft=94584ms decodeTPS=5.1 finish=length
    req 7: prompt=4000 tokens=64 ttft=94584ms decodeTPS=5.1 finish=length
