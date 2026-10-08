/// Private benchmark output envelope only. Every original artifact, path,
/// profile, lifetime, phase and actual resource gate remains authoritative.
enum Gemma4BenchmarkOutputEnvelope {
    static func allows(outputCount: Int, mode: String, promptCount: Int,
                       chunkSize: Int, cut: Int, residualDType: String) -> Bool {
        if outputCount == 16 { return true } // Preserve the original output gate.
        return outputCount == 128 && mode == "full"
            && [128,4096].contains(promptCount) && chunkSize == 64
            && cut == 7 && residualDType == "bfloat16"
    }
}
