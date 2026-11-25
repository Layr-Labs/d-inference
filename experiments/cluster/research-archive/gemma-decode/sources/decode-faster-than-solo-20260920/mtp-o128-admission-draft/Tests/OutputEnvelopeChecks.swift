@main struct OutputEnvelopeChecks {
    enum Failure: Error { case unexpectedAdmission, groupCount }
    static func check(_ value: Bool) throws { if !value { throw Failure.unexpectedAdmission } }
    static func finish(_ groups: Int) throws {
        guard groups == 8 else { throw Failure.groupCount }
        print("PASS \(groups) output-envelope groups; no MLX, native, model or admission observation")
    }
    static func allows(_ output: Int = 128, mode: String = "full", prompt: Int = 128,
                       chunk: Int = 64, cut: Int = 7, dtype: String = "bfloat16") -> Bool {
        Gemma4BenchmarkOutputEnvelope.allows(outputCount:output,mode:mode,promptCount:prompt,
            chunkSize:chunk,cut:cut,residualDType:dtype)
    }
    static func main() throws {
        var groups=0
        // This helper preserves only the original output predicate. Existing
        // caller validation still rejects other invalid fields for O16.
        for mode in ["full","stage0","stage1"] {
            for prompt in [128,256,1024,4096,8192] {
                for cut in [6,7,8,10] { try check(allows(16,mode:mode,prompt:prompt,cut:cut)) }
            }
        };groups += 1
        for prompt in [128,4096] { try check(allows(prompt:prompt)) };groups += 1
        for output in [Int.min,-1,0,1,15,17,127,129,Int.max] { try check(!allows(output)) };groups += 1
        for mode in ["stage0","stage1","","FULL","assistant"] { try check(!allows(mode:mode)) };groups += 1
        for prompt in [0,127,129,256,1024,8192,Int.max] { try check(!allows(prompt:prompt)) };groups += 1
        for chunk in [0,16,63,65,128,Int.max] { try check(!allows(chunk:chunk)) };groups += 1
        for cut in [0,6,8,10,30,Int.max] { try check(!allows(cut:cut)) };groups += 1
        for dtype in ["float16","float32","","BF16"] { try check(!allows(dtype:dtype)) };groups += 1
        try finish(groups)
    }
}
