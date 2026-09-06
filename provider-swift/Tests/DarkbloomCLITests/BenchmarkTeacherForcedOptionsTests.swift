import ArgumentParser
import Testing
@testable import darkbloom

@Suite("Teacher-forced benchmark option scope")
struct BenchmarkTeacherForcedOptionsTests {
    private let base = ["--teacher-forced-input", "/tmp/input.json", "--model", "target", "--kv-backend", "paged"]

    @Test func explicitOrdinaryModeParsesAndDefaultIsUnchanged() throws {
        let selected = try Benchmark.parse(base)
        #expect(selected.teacherForcedInput == "/tmp/input.json")
        #expect(selected.teacherForcedOptionError() == nil && selected.benchmarkModeConflict() == nil)
        let ordinary = try Benchmark.parse([])
        #expect(ordinary.teacherForcedInput == nil && ordinary.teacherForcedOptionError() == nil)
    }

    @Test func incompatibleModesAndAssistantAreRefused() throws {
        for option in ["--parity", "--sweep", "--scheduler-prefill", "--arrival-invariance", "--scheduler-prefill-decision"] {
            #expect(try Benchmark.parse(base + [option]).benchmarkModeConflict() != nil)
        }
        #expect(try Benchmark.parse(base + ["--assistant-model", "draft"]).teacherForcedOptionError() != nil)
        #expect(try Benchmark.parse(base + ["--output", "/tmp/out"]).teacherForcedOptionError() != nil)
        #expect(try Benchmark.parse(["--teacher-forced-input", "/tmp/in"]).teacherForcedOptionError() != nil)
        #expect(try Benchmark.parse(["--teacher-forced-input", "/tmp/in", "--model", "target"]).teacherForcedOptionError() != nil)
    }
}
