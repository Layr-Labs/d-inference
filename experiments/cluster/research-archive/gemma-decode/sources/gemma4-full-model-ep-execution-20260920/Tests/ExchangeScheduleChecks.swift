import Foundation

@main struct ExchangeScheduleChecks {
    enum Failure: Error { case check }
    static func main() throws {
        var groups = 0
        func require(_ value: Bool) throws { guard value else { throw Failure.check } }
        func refuses(_ body: () throws -> Void) throws {
            do { try body() } catch { return }; throw Failure.check
        }
        func probe(_ value: inout Gemma4ExpertExchangeSchedule) throws {
            try value.begin()
            for frame in Gemma4ExpertExchangeSchedule.probeFrames {
                for layer in 0..<30 {
                    try value.completeExchange(purpose: "probe", frame: frame, layer: layer)
                }
            }
            try value.ready()
        }
        func requestFrame(_ value: inout Gemma4ExpertExchangeSchedule, _ index: Int) throws {
            let frame = Gemma4ExpertExchangeSchedule.requestFrames[index]
            for layer in 0..<30 {
                try value.requireExchange(purpose: "request", frame: frame, layer: layer)
                try value.completeExchange(purpose: "request", frame: frame, layer: layer)
            }
        }
        var value = Gemma4ExpertExchangeSchedule()
        try probe(&value)
        for index in 0..<3 {
            try requestFrame(&value,index)
            try value.committed(Gemma4ExpertExchangeSchedule.requestFrames[index])
        }
        try require(value.completedExchanges == 150 && !value.failed && !value.released)
        try value.retire(); try value.releaseModel(); try require(value.released)
        groups += 1
        try refuses { try value.releaseModel() }; try require(value.failed); groups += 1
        value = .init(); try refuses { try value.ready() }; try require(value.failed); groups += 1
        value = .init(); try value.begin()
        try refuses { try value.completeExchange(purpose: "request", frame: .init(sequence: 0,
            phase: "prefill", offset: 0, count: 16, finalPrompt: false), layer: 0) }
        try require(value.completedExchanges == 0 && value.failed); groups += 1
        value = .init(); try value.begin()
        try refuses { try value.completeExchange(purpose: "probe",
            frame: Gemma4ExpertExchangeSchedule.probeFrames[0], layer: 1) }; groups += 1
        value = .init(); try value.begin()
        try refuses { try value.completeExchange(purpose: "probe", frame: .init(sequence: 0,
            phase: "prefill", offset: 1, count: 2, finalPrompt: true), layer: 0) }; groups += 1
        value = .init(); try probe(&value)
        try refuses { try value.committed(Gemma4ExpertExchangeSchedule.requestFrames[0]) }; groups += 1
        value = .init(); try probe(&value); try requestFrame(&value,0)
        try refuses { try value.completeExchange(purpose: "request",
            frame: Gemma4ExpertExchangeSchedule.requestFrames[1], layer: 0) }; groups += 1
        value = .init(); try probe(&value); try requestFrame(&value,0)
        try refuses { try value.committed(Gemma4ExpertExchangeSchedule.requestFrames[1]) }; groups += 1
        value = .init(); try probe(&value); try requestFrame(&value,0)
        try value.committed(Gemma4ExpertExchangeSchedule.requestFrames[0])
        try refuses { try value.committed(Gemma4ExpertExchangeSchedule.requestFrames[0]) }; groups += 1
        value = .init(); try probe(&value); try refuses { try value.retire() }; groups += 1
        value = .init(); try probe(&value); try refuses { try value.releaseModel() }; groups += 1
        value = .init(); try value.begin(); value.poison()
        try refuses { try value.begin() }
        try refuses { try value.completeExchange(purpose: "probe",
            frame: Gemma4ExpertExchangeSchedule.probeFrames[0], layer: 0) }
        try require(value.failed && value.completedExchanges == 0); groups += 1
        print("PASS \(groups) Gemma full expert exchange schedule groups (Foundation only)")
    }
}
