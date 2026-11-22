import Foundation
import Testing
@testable import ProviderCore

/// Whose request a submission is (`ServingRoute`), and the one table of what each limit decides for it
/// (`RoutePolicy`). `golden` is a pin, not an oracle: a second copy of every cell, so that a change to a cell, which
/// is a change to what a client or the coordinator gets, takes a second hand. It cannot say a cell is right.
///
/// The oracle is `ServingRouteLimitTests`, which drives real engine paths. It reaches memory on one Mac and on a
/// pair, one Mac's engine queue, and a pair's first-token allowance, request deadline and context. It does not reach:
/// - `mediaMemory`, which `EngineV2VisionRoutingTests` exercises for the owner's request and for any other;
/// - a loop exit's continuation on a pair, refused for its priority before a limit matters. Only its `context` is
///   seen, through `EngineV2Bridge.outputTokens` (`PairOwnerContextTests`);
/// - a pair's `engineQueue`, and one Mac's `firstToken`, `requestDeadline` and `context`: the same for every route,
///   with nothing on that front end for them to change.
@Suite("The serving route and its policy table")
struct ServingRoutePolicyTests {
    typealias Limits = RouteLimits

    /// One request of each route, by name. The switch in `name(of:)` has no default: a new route does not compile
    /// here until it has a name. Its rows are added by hand: the routes carry values and cannot be enumerated, so
    /// `everyCellIsDecidedAsToday` fails when a route listed here loses its rows, not when a new one has none yet.
    /// What the compiler holds to every route is `RoutePolicy`'s own switches (`thePolicyTableNamesEveryCase`).
    static let routes: [(name: String, route: ServingRoute)] = [
        ("coordinator", .coordinator(nil)),
        ("coordinator, with a first-content budget", .coordinator(FirstContentDeadline(relativeBudgetMilliseconds: 60_000))),
        ("owner", .owner(OwnerMemoryWait())),
        ("owner, first-token allowance restored", .owner(OwnerMemoryWait(waitsForFirstToken: false))),
        ("owner's continuation", .ownerContinuation),
        ("internal", .internal),
    ]

    static func name(of route: ServingRoute) -> String {
        switch route {
        case .coordinator: return "coordinator"
        case .owner: return "owner"
        case .ownerContinuation: return "owner's continuation"
        case .internal: return "internal"
        }
    }

    static func row(_ memory: Limits.Memory, _ engineQueue: Limits.EngineQueue, _ firstToken: Limits.FirstToken,
                    _ requestDeadline: Limits.RequestDeadline, _ context: Limits.Context) -> Limits {
        Limits(memory: memory, engineQueue: engineQueue, mediaMemory: .refusedAtOnce,
               firstToken: firstToken, requestDeadline: requestDeadline, context: context)
    }

    /// Today's decision in every cell. A Darkbloom request is refused at once wherever the owner's waits, keeps the
    /// pair's first-token allowance and the setup's request timeout, and is held to what the pair reports.
    static let golden: [ServingFrontEnd: [String: Limits]] = [
        .oneMac: [
            "coordinator": row(.refusedAtOnce, .endsWithTheEnginesLease, .noAllowance, .enginesOwn, .modelWindow),
            "coordinator, with a first-content budget":
                row(.refusedAtOnce, .endsWithTheEnginesLease, .noAllowance, .enginesOwn, .modelWindow),
            "owner": row(.waitsWithinOwnersBound, .heldAndSubmittedAgain, .noAllowance, .enginesOwn, .modelWindow),
            "owner, first-token allowance restored":
                row(.waitsWithinOwnersBound, .heldAndSubmittedAgain, .noAllowance, .enginesOwn, .modelWindow),
            "owner's continuation":
                row(.refusedAtOnce, .endsWithTheEnginesLease, .noAllowance, .enginesOwn, .modelWindow),
            "internal": row(.refusedAtOnce, .endsWithTheEnginesLease, .noAllowance, .enginesOwn, .modelWindow),
        ],
        .pair: [
            "coordinator": row(.refusedAtOnce, .noQueue, .pairAllowance, .setupRequestTimeout, .pairServed),
            "coordinator, with a first-content budget":
                row(.refusedAtOnce, .noQueue, .pairAllowance, .setupRequestTimeout, .pairServed),
            "owner": row(.waitsWithinOwnersBound, .noQueue, .noAllowance, .protocolHour, .pairOwnerServed),
            "owner, first-token allowance restored":
                row(.waitsWithinOwnersBound, .noQueue, .pairAllowance, .protocolHour, .pairOwnerServed),
            "owner's continuation": row(.refusedAtOnce, .noQueue, .pairAllowance, .protocolHour, .pairOwnerServed),
            "internal": row(.refusedAtOnce, .noQueue, .pairAllowance, .setupRequestTimeout, .pairServed),
        ],
    ]

    @Test func everyCellIsDecidedAsToday() {
        for frontEnd in ServingFrontEnd.allCases {
            for (name, route) in Self.routes {
                #expect(RoutePolicy.limits(for: route, at: frontEnd) == Self.golden[frontEnd]?[name],
                        "\(name) at \(frontEnd)")
            }
        }
        // No route was dropped from the list above.
        #expect(Set(Self.routes.map { Self.name(of: $0.route) })
                == ["coordinator", "owner", "owner's continuation", "internal"])
    }

    /// The provider's own request and a Darkbloom request, with a budget or without, get the same decision in every
    /// cell today: only the owner's route differs.
    @Test func theProvidersOwnRequestIsDecidedAsADarkbloomRequest() {
        let budget = FirstContentDeadline(relativeBudgetMilliseconds: 60_000)
        for frontEnd in ServingFrontEnd.allCases {
            let darkbloom = RoutePolicy.limits(for: .coordinator(nil), at: frontEnd)
            #expect(RoutePolicy.limits(for: .internal, at: frontEnd) == darkbloom)
            #expect(RoutePolicy.limits(for: .coordinator(budget), at: frontEnd) == darkbloom)
        }
    }

    /// The route is the owner's exactly where the rule this replaced said so: the owner's wait bound and no
    /// coordinator budget, its first submission at priority 0 and a loop exit's continuation above it. A budget or
    /// the coordinator's id makes any other request the coordinator's. The budget travels with the route unchanged.
    @Test func theRouteIsResolvedFromWhatTheRequestCarries() {
        let budget = FirstContentDeadline(relativeBudgetMilliseconds: 60_000)
        for deadline in [nil, budget] as [FirstContentDeadline?] {
            for wait in [nil, OwnerMemoryWait()] as [OwnerMemoryWait?] {
                for priority in [0, 1] {
                    for darkbloom in [false, true] {
                        let route = ServingRoute.resolve(firstContentDeadline: deadline, ownerWait: wait,
                                                         admissionPriority: priority, darkbloomRequest: darkbloom)
                        let owners = wait != nil && deadline == nil
                        let expected = owners ? (priority == 0 ? "owner" : "owner's continuation")
                            : deadline != nil || darkbloom ? "coordinator" : "internal"
                        #expect(Self.name(of: route) == expected,
                                "budget \(deadline != nil), wait \(wait != nil), priority \(priority), id \(darkbloom)")
                        #expect(route.firstContentDeadline == deadline)
                    }
                }
            }
        }
    }

    /// The route of the task: its owner's wait, admission priority and coordinator id, as each front end binds them.
    @Test func theRouteOfATaskReadsWhatIsBoundAroundIt() {
        #expect(Self.name(of: .current(firstContentDeadline: nil)) == "internal")
        OwnerMemoryWait.$current.withValue(OwnerMemoryWait()) {
            #expect(Self.name(of: .current(firstContentDeadline: nil)) == "owner")
            EngineAdmissionPriority.$current.withValue(1) {
                #expect(Self.name(of: .current(firstContentDeadline: nil)) == "owner's continuation")
            }
            #expect(Self.name(of: .current(firstContentDeadline: .init(relativeBudgetMilliseconds: 1_000)))
                    == "coordinator")
        }
        MeFirstDarkbloomRequest.$id.withValue("request") {
            #expect(Self.name(of: .current(firstContentDeadline: nil)) == "coordinator")
        }
    }

    /// The pair's own types carry the decision as a flag (the cluster checks compile them alone): true exactly for
    /// the owner's limits.
    @Test func thePairsFlagIsTheOwnersLimits() {
        #expect(Limits.Context.pairOwnerServed.servesOwner)
        #expect(!Limits.Context.pairServed.servesOwner && !Limits.Context.modelWindow.servesOwner)
    }

    // MARK: - Tripwires beside the compiler's guarantees

    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    /// The table decides every route and front end by name: no `default:` and no wildcard that a new case would
    /// fall into unseen.
    @Test func thePolicyTableNamesEveryCase() throws {
        let table = Self.sources.appendingPathComponent("ProviderCore/Inference/Engine/Bridge/ServingRoute.swift")
        let lines = try String(contentsOf: table, encoding: .utf8).components(separatedBy: "\n")
        let code = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(code.count > 100, "the table was not read")
        #expect(code.filter { $0.contains("default:") || $0.contains("case _") || $0.contains("@unknown") } == [])
    }

    /// No production source takes the route or the front end with a default, nor the flag the pair's own types
    /// carry the route as (`ownerRequest`; the cluster checks compile those files alone, so they cannot name the
    /// route), nor one of the flags the route replaced. A new parameter cannot quietly give a caller a Darkbloom
    /// request's limits.
    @Test func noCallerGetsARouteItDidNotName() throws {
        let defaulted = [
            "ownerRequest:Bool=", "appliesDistributedFirstTokenBudget:Bool=", "holdsOwnerHead:Bool=",
            ":ServingRoute=", ":ServingRoute?=", ":ServingFrontEnd=", ":ServingFrontEnd?=",
        ]
        let files = try #require(FileManager.default.enumerator(at: Self.sources, includingPropertiesForKeys: nil))
        var scanned = 0, defaults: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            scanned += 1
            for line in try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n") {
                let code = line.replacingOccurrences(of: " ", with: "")
                if defaulted.contains(where: code.contains) {
                    defaults.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(scanned > 500, "the sources were not scanned")
        #expect(defaults == [])
    }
}
