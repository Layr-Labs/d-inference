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
        #expect(ordinary.exactModelDirectoryOverride() == nil)
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

    @Test func exactDirectoryOverrideRequiresIdentityAndTeacherForcedMode() throws {
        let selected = try Benchmark.parse(base + ["--model-directory", "/tmp/exact artifact view"])
        #expect(selected.teacherForcedOptionError() == nil && selected.modelDirectoryOptionError() == nil)
        #expect(selected.exactModelDirectoryOverride()?.path == "/tmp/exact artifact view")
        #expect(selected.model == "target")
        #expect(try Benchmark.parse(base).exactModelDirectoryOverride() == nil)
        #expect(try Benchmark.parse(base + ["--expected-model-aggregate-sha256", String(repeating: "a", count: 64)]).teacherForcedOptionError() != nil)
        for arguments in [
            ["--model-directory", "/tmp/view"],
            ["--model-directory", "/tmp/view", "--teacher-forced-input", "/tmp/input", "--kv-backend", "paged"],
            base + ["--model-directory", "   "],
        ] {
            #expect(try Benchmark.parse(arguments).modelDirectoryOptionError() != nil)
        }
        for mode in ["--parity", "--sweep", "--scheduler-prefill", "--arrival-invariance", "--scheduler-prefill-decision"] {
            let withoutTeacher = try Benchmark.parse([mode, "--model", "target", "--model-directory", "/tmp/view"])
            #expect(withoutTeacher.modelDirectoryOptionError() != nil)
            let conflicting = try Benchmark.parse(base + [mode, "--model-directory", "/tmp/view"])
            #expect(conflicting.modelDirectoryOptionError() != nil)
            #expect(conflicting.exactModelDirectoryOverride() == nil)
        }
    }
}
