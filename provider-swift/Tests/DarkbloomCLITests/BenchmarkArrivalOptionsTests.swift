import ArgumentParser
import Testing

@testable import darkbloom

@Suite("benchmark arrival options")
struct BenchmarkArrivalOptionsTests {
    @Test
    func arrivalBatchSizeDefaultsToFour() throws {
        let command = try Benchmark.parse([])
        #expect(command.arrivalBatchSize == 4)
    }

    @Test
    func arrivalBatchSizeAcceptsExactlyOneTwoFour() throws {
        for batchSize in [1, 2, 4] {
            let command = try Benchmark.parse([
                "--arrival-invariance",
                "--arrival-batch-size", String(batchSize),
            ])
            #expect(command.arrivalBatchSize == batchSize)
        }

        for batchSize in [Int.min, -1, 0, 3, 5, Int.max] {
            #expect(throws: (any Error).self) {
                _ = try Benchmark.parse([
                    "--arrival-invariance",
                    "--arrival-batch-size", String(batchSize),
                ])
            }
        }
    }
}
