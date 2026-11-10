import Foundation
import Darwin

/// The owner, 2026-11-05: "at the top of the Dark Bloom logo, if it's darkbloom cluster, put lead and or member … so the
/// user always knows which machine is the leader, and which is the member." A paired Mac's opening names its part by the
/// mark ("Leading Mac", "Joining Mac", the screens' own words), on both Macs, at 80 and 40 columns and in plain output once.
extension OnboardingChecks {
    static func roleHeaderChecks() {
        let leader = ClusterOnboardingResume(role: .leader, peerName: "Apple M5 Max, 128 GB", serving: true, modelName: "Qwen3.8-27B-4bit-mtp")
        for (label, resume, role, other) in [("leading", leader, "Leading Mac", "Joining Mac"), ("joining", memberResume(), "Joining Mac", "Leading Mac")] {
            for (presentation, environment, columns) in [("80 columns", colourTerminal, 80), ("40 columns", colourTerminal, 40),
                                                          ("plain", ["NO_COLOR": "1"], 80)] as [(String, [String: String], UInt16)] {
                let run = TerminalRun(operations(Recorder(), resume: resume, pairEvents: [], pairResult: .failed([])),
                                      environment: environment, columns: columns)
                defer { run.release() }
                expect(run.waitFor(presentation == "plain" ? (label == "leading" ? prompt(4) : prompt(2)) : arrowHint),
                       "role, \(label) Mac, \(presentation): the screen")
                run.type("q")
                _ = run.finish()
                let screen = visible(run.text)
                let top = screen.prefix(8)
                expect(top.contains { $0.contains(role) }, "role, \(label) Mac, \(presentation): named at the top: \(Array(top))")
                expect(!run.text.contains(other), "role, \(label) Mac, \(presentation): never the other part: \(run.text)")
                expect(screen.filter { $0.contains(role) }.count == 1, "role, \(label) Mac, \(presentation): said once")
                let titled = screen.filter { $0.contains(role) }
                expect(titled.allSatisfy { $0.count <= Int(columns) }, "role, \(label) Mac, \(presentation): the title fits: \(titled)")
                if presentation == "plain" {
                    expect(screen.contains("Darkbloom cluster \u{00B7} \(role)"), "role, \(label) Mac, plain: the title line: \(Array(top))")
                }
                transcript("role-\(label)-\(presentation.replacingOccurrences(of: " ", with: "-"))", screen.joined(separator: "\n"), keys: run.keys)
            }
        }
        // Before pairing no part is known: the title alone.
        let fresh = TerminalRun(operations(Recorder(), pairEvents: memberEvents, pairResult: .failed(["Cancelled: nothing paired."])))
        defer { fresh.release() }
        _ = fresh.finish(seconds: 20)
        expect(fresh.text.contains("Darkbloom cluster") && !fresh.text.contains("Leading Mac") && !fresh.text.contains("Joining Mac"),
               "role, before pairing: the title alone: \(fresh.text.prefix(300))")
    }
}
