import Foundation
import ArgumentParser
import ProviderCore

// `darkbloom energy` — live SoC power/energy readout, sudoless via IOReport.
//
// Standalone meter (independent of the running provider): shows what the Mac is
// drawing right now, split by subsystem (CPU / GPU / ANE / DRAM). The per-
// operation attribution (idle vs prefill vs decode) is produced by the running
// provider's EnergyAccountant and reported to the coordinator on the heartbeat;
// this command is for spot-checking the raw numbers on the box.
struct Energy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "energy",
        abstract: "Live SoC power/energy readout (sudoless, via IOReport)."
    )

    @Option(name: .long, help: "Sampling interval in milliseconds.")
    var intervalMs: Int = 1000

    @Option(name: .long, help: "Number of samples to print (0 = until interrupted).")
    var count: Int = 10

    @Flag(name: .long, help: "Emit JSON lines instead of a table.")
    var json: Bool = false

    struct Reading: Encodable {
        let watts: Double
        let cpuWatts: Double
        let gpuWatts: Double
        let aneWatts: Double
        let dramWatts: Double
    }

    func run() async throws {
        Darkbloom.ensureLogging()

        let sampler = IOReportSampler()
        guard await sampler.available else {
            printError("IOReport energy measurement is unavailable on this system.")
            throw ExitCode.failure
        }

        if !json {
            printError("Live SoC power (sudoless via IOReport). interval=\(intervalMs)ms")
            print(String(format: "%-5@  %8@  %8@  %8@  %8@  %10@",
                         "#" as NSString, "CPU" as NSString, "GPU" as NSString,
                         "ANE" as NSString, "DRAM" as NSString, "TOTAL" as NSString))
        }

        let interval = UInt64(max(100, intervalMs)) * 1_000_000
        var samples = 0
        var totalJoules = 0.0
        var sumWatts = 0.0

        while count == 0 || samples < count {
            try? await Task.sleep(nanoseconds: interval)
            guard let s = await sampler.sample(), s.seconds > 0 else { continue }
            let cpu = s.cpuJoules / s.seconds
            let gpu = s.gpuJoules / s.seconds
            let ane = s.aneJoules / s.seconds
            let dram = s.dramJoules / s.seconds
            let total = s.totalJoules / s.seconds
            samples += 1
            totalJoules += s.totalJoules
            sumWatts += total

            if json {
                let r = Reading(watts: total, cpuWatts: cpu, gpuWatts: gpu, aneWatts: ane, dramWatts: dram)
                try? printJSON(r)
            } else {
                print(String(format: "%-5d  %6.2fW  %6.2fW  %6.2fW  %6.2fW  %8.2fW",
                             samples, cpu, gpu, ane, dram, total))
            }
        }

        if !json && samples > 0 {
            let avg = sumWatts / Double(samples)
            let wh = totalJoules / 3600.0
            printError(String(format: "avg %.2f W   energy %.4f Wh over %d samples", avg, wh, samples))
        }
    }
}
