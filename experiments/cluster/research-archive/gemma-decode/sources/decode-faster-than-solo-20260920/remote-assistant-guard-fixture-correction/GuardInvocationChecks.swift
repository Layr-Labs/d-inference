import Foundation

@main struct GuardInvocationChecks {
    typealias G = Gemma4BenchmarkGuardInvocation
    static func fresh(_ mode: G.Mode = .entryOwner) -> G {
        G(mode: mode, deadline: 200, created: 10, maximumAge: 100)
    }
    static func accept(_ g: inout G, _ consumer: G.Consumer, now: UInt64 = 20) throws {
        try g.accept(consumer, started: 11, completed: 12, expectedDeadline: 200, now: now)
    }
    static func refuses(_ expected: G.Failure, _ body: () throws -> Void) throws {
        do { try body() } catch let failure as G.Failure {
            guard failure == expected else { throw failure }; return
        }
        throw NSError(domain: "missing expected guard refusal", code: 1)
    }
    static func requireGroupCount(_ count: Int) throws {
        guard count == 13 else { throw NSError(domain:"group count",code:2) }
    }
    static func main() throws {
        var groups = 0
        for (mode, consumers) in [(G.Mode.entry,[G.Consumer.entry]),(.owner,[.owner]),(.combined,[.entry,.owner,.entry])] {
            var g=fresh(mode);for c in consumers { try accept(&g,c) };try g.finish(expectedDeadline:200,now:20)
        };groups += 1
        var g=fresh();try accept(&g,.entry);try accept(&g,.owner);try g.finish(expectedDeadline:200,now:20);groups += 1
        g=fresh();try refuses(.wrongConsumer) { try accept(&g,.owner) };groups += 1
        g=fresh();try accept(&g,.entry);try refuses(.wrongConsumer) { try accept(&g,.entry) };groups += 1
        g=fresh();try accept(&g,.entry);try accept(&g,.owner);try refuses(.wrongConsumer) { try accept(&g,.entry) };groups += 1
        g=fresh();try accept(&g,.entry);try refuses(.incomplete) { try g.finish(expectedDeadline:200,now:20) };groups += 1
        g=fresh();try refuses(.expired) { try accept(&g,.entry,now:200) };groups += 1
        g=fresh();try refuses(.invalidConfiguration) { try g.preflight(.entry,expectedDeadline:201,now:20) };groups += 1
        g=fresh();try refuses(.staleObservation) { try g.accept(.entry,started:9,completed:12,expectedDeadline:200,now:20) };groups += 1
        g=fresh();try refuses(.expired) { try accept(&g,.entry,now:111) };groups += 1
        g=fresh();g.close();try refuses(.closed) { try accept(&g,.entry) };groups += 1
        g=fresh();try refuses(.expired) { try accept(&g,.entry,now:9) };groups += 1
        g=fresh();try accept(&g,.entry);try accept(&g,.owner);try g.finish(expectedDeadline:200,now:20)
        try refuses(.closed) { try g.finish(expectedDeadline:200,now:20) };groups += 1
        try requireGroupCount(groups)
        print("PASS \(groups) fresh-observation chronology groups; no OS, native, MLX or GPU")
    }
}
