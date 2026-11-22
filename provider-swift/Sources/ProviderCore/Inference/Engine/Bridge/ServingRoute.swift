// Whose request a submission is, and what every limit that depends on it decides.

import Foundation

/// Whose request the bridge submits. Resolved once per submission (`EngineV2Bridge.submitTokenized`) from what the
/// request's task carries, then passed down as a value. No limit works it out for itself: each reads its decision
/// from `RoutePolicy.limits(for:at:)`.
enum ServingRoute: Sendable {
    /// A request the coordinator sent, with the first-content budget it reaches the bridge with: nil when it names
    /// none, or when its route keeps the budget to itself (Nemotron Super's).
    case coordinator(FirstContentDeadline?)
    /// The owner's own request on this Mac's local API (a pair's, on its leader), with how it waits.
    case owner(OwnerMemoryWait)
    /// The answer of an owner's request whose thought a loop exit ended (`LoopExitThinkingContinuation`): the
    /// owner's limits, but it takes its stopped row's place and never waits.
    case ownerContinuation
    /// A request with neither: one the provider submits for itself (a calibration probe, a warm-up, a preload).
    /// Today also the owner's request on Nemotron Super's local route, which binds no owner's wait
    /// (`NemotronSuperLocalImageHTTP`), so it is refused at once where the owner's request on any other model waits.
    case `internal`

    /// The route of the request this task serves, by `resolve`, from the request-scoped values bound around it:
    /// the owner's wait (`MultiModelBatchSchedulerEngine` binds the local API's), the engine admission priority
    /// (`LoopExitThinkingContinuation` raises it) and the coordinator's request id (`ProviderLoop` binds it).
    static func current(firstContentDeadline: FirstContentDeadline?) -> ServingRoute {
        resolve(firstContentDeadline: firstContentDeadline, ownerWait: OwnerMemoryWait.current,
                admissionPriority: EngineAdmissionPriority.current, darkbloomRequest: MeFirstDarkbloomRequest.id != nil)
    }

    /// The one rule. The owner's: its wait is bound and the request has no coordinator budget (one with a budget is
    /// never the owner's, whatever its task inherited); its first submission has priority 0, a loop exit's
    /// continuation a higher one. Else the coordinator's: it has a budget, or the coordinator's id. Else the
    /// provider's own.
    static func resolve(firstContentDeadline: FirstContentDeadline?, ownerWait: OwnerMemoryWait?,
                        admissionPriority: Int, darkbloomRequest: Bool) -> ServingRoute {
        if let ownerWait, firstContentDeadline == nil {
            return admissionPriority == 0 ? .owner(ownerWait) : .ownerContinuation
        }
        if firstContentDeadline != nil || darkbloomRequest { return .coordinator(firstContentDeadline) }
        return .internal
    }

    /// The coordinator's first-content budget: only its own request has one.
    var firstContentDeadline: FirstContentDeadline? {
        switch self {
        case .coordinator(let deadline): return deadline
        case .owner, .ownerContinuation, .internal: return nil
        }
    }
}

/// What serves a request. A bridge tells `.oneMac` from `.pair` by its engine. Nemotron Super's bridges are built as
/// any Mac's, and its admission runs before them, so only Super's own route could state `.nemotronSuper`. It does
/// not yet: that row of `RoutePolicy` says what Super's admission does today, and no code reads it.
enum ServingFrontEnd: CaseIterable, Sendable {
    case oneMac
    case pair
    case nemotronSuper
}

/// What each limit that depends on the route decides for one request. One stored property per limit, none with a
/// default: a new limit does not compile until `RoutePolicy.limits(for:at:)` decides it, in a switch over every
/// route and front end.
struct RouteLimits: Equatable, Sendable {
    /// The memory that requests already running hold, when the request can't start for it.
    enum Memory: Equatable, Sendable {
        /// Refused at once: the coordinator sends a Darkbloom request elsewhere within its first-content budget.
        case refusedAtOnce
        /// Waits for a running request to end and is submitted again, within the owner's bound
        /// (`OwnerMemoryWait.effectiveLimit`; none: as long as it takes).
        case waitsWithinOwnersBound
    }

    /// The engine's queue: a request the engine queued, then ended before admitting it (its 120 s admission lease,
    /// a full paged pool's requeues).
    enum EngineQueue: Equatable, Sendable {
        /// The engine's end is the request's: `admission_timeout` to the coordinator.
        case endsWithTheEnginesLease
        /// Its response head waits for the admission, streamed or not; ended before it, the request waits as for
        /// memory and is submitted again (`EngineV2Bridge.holdHeadUntilAdmitted`).
        case heldAndSubmittedAgain
        /// No engine queue to wait in: a pair's lanes are taken before its engine.
        case noQueue
    }

    /// A place to run, taken before the engine. Its front ends decide it themselves and do not read this value
    /// (`DistributedLocalServer.waitForTurn`, `ProviderLoop.takeClusterPairLane`,
    /// `NemotronSuperLocalImageHTTP.streamChatCompletion`): it states what they do, so that changing either is a
    /// decision made here.
    enum Slot: Equatable, Sendable {
        /// Nothing before the engine.
        case none
        /// A pair's lane queue: in arrival order, until `DistributedRequestQueue.Limits.waitCeiling`, then 503. The
        /// ceiling counts in the setup's request timeout, though each of the owner's requests ahead may run for
        /// the protocol's hour (`RequestDeadline.protocolHour`).
        case pairLaneCeiling
        /// Nemotron Super's admission: at most `NemotronSuperServingPolicy.finishingWait` (1 s) once every admitted
        /// answer has ended, a media request at most `stackedMediaWait` (3 s) behind media answers already
        /// streaming, one waiter at a time; otherwise 429 at once.
        case nemotronSuperSettling
    }

    /// The media memory gate (`VisionMemoryGate`), where one is bound, and Nemotron Super's own media charge.
    enum MediaMemory: Equatable, Sendable {
        /// Refused at once as `media_memory_unavailable`.
        case refusedAtOnce
    }

    /// The time to the first token, beside a coordinator's own first-content budget.
    enum FirstToken: Equatable, Sendable {
        /// No allowance: the request's deadline bounds it.
        case noAllowance
        /// The pair's first-token allowance (`DistributedFirstTokenBudgetPolicy`).
        case pairAllowance
    }

    /// How long the request may run.
    enum RequestDeadline: Equatable, Sendable {
        /// The engine's own safety ceiling, the same for every route.
        case enginesOwn
        /// The pair setup's request timeout (`DistributedResidentExecutionProfile.requestTimeout`).
        case setupRequestTimeout
        /// The worker protocol's hour (`DistributedCBv2Engine.ownerRequestTimeout`).
        case protocolHour
    }

    /// The prompt, output and context the request is held to.
    enum Context: Equatable, Sendable {
        /// One Mac's model window, the same for every route.
        case modelWindow
        /// What the pair reports to the coordinator (`DistributedResidentExecutionProfile.served`).
        case pairServed
        /// What the pair serves its owner (`DistributedResidentExecutionProfile.ownerServed`).
        case pairOwnerServed

        /// This decision as the pair's own types carry it (`DistributedRequestDeadlineContext.ownerRequest`,
        /// `DistributedResidentExecutionProfile.limits(ownerRequest:)`): the cluster checks compile those files
        /// alone, so they cannot name the route.
        var servesOwner: Bool {
            switch self {
            case .pairOwnerServed: return true
            case .pairServed, .modelWindow: return false
            }
        }
    }

    let memory: Memory
    let engineQueue: EngineQueue
    let slot: Slot
    let mediaMemory: MediaMemory
    let firstToken: FirstToken
    let requestDeadline: RequestDeadline
    let context: Context
}

/// The one table of what each limit decides per route and front end. Every switch names every case, so a new
/// route or front end does not compile until every limit decides it.
enum RoutePolicy {
    static func limits(for route: ServingRoute, at frontEnd: ServingFrontEnd) -> RouteLimits {
        RouteLimits(memory: memory(route, frontEnd), engineQueue: engineQueue(route, frontEnd),
                    slot: slot(route, frontEnd), mediaMemory: mediaMemory(route, frontEnd),
                    firstToken: firstToken(route, frontEnd), requestDeadline: requestDeadline(route, frontEnd),
                    context: context(route, frontEnd))
    }

    private static func memory(_ route: ServingRoute, _ frontEnd: ServingFrontEnd) -> RouteLimits.Memory {
        switch frontEnd {
        case .oneMac, .pair:
            switch route {
            case .owner: return .waitsWithinOwnersBound
            case .coordinator, .ownerContinuation, .internal: return .refusedAtOnce
            }
        case .nemotronSuper:
            // Not a decision yet: Super's local route binds no owner's wait, so nothing waits there.
            switch route {
            case .coordinator, .owner, .ownerContinuation, .internal: return .refusedAtOnce
            }
        }
    }

    private static func engineQueue(_ route: ServingRoute, _ frontEnd: ServingFrontEnd) -> RouteLimits.EngineQueue {
        switch frontEnd {
        case .oneMac:
            switch route {
            case .owner: return .heldAndSubmittedAgain
            case .coordinator, .ownerContinuation, .internal: return .endsWithTheEnginesLease
            }
        case .pair:
            switch route {
            case .coordinator, .owner, .ownerContinuation, .internal: return .noQueue
            }
        case .nemotronSuper:
            switch route {
            case .coordinator, .owner, .ownerContinuation, .internal: return .endsWithTheEnginesLease
            }
        }
    }

    private static func slot(_ route: ServingRoute, _ frontEnd: ServingFrontEnd) -> RouteLimits.Slot {
        switch frontEnd {
        case .oneMac:
            switch route {
            case .coordinator, .owner, .ownerContinuation, .internal: return .none
            }
        case .pair:
            switch route {
            case .owner: return .pairLaneCeiling
            // A Darkbloom request never queues for a lane (with none free it is refused at once, `memory`), and a
            // continuation runs in its request's lane.
            case .coordinator, .ownerContinuation, .internal: return .none
            }
        case .nemotronSuper:
            // One admission for Darkbloom and local requests alike.
            switch route {
            case .coordinator, .owner, .ownerContinuation, .internal: return .nemotronSuperSettling
            }
        }
    }

    private static func mediaMemory(_ route: ServingRoute, _ frontEnd: ServingFrontEnd) -> RouteLimits.MediaMemory {
        switch frontEnd {
        case .oneMac, .pair, .nemotronSuper:
            // Not a decision yet for the owner's: its memory wait covers the engine's memory, not the media gate.
            switch route {
            case .coordinator, .owner, .ownerContinuation, .internal: return .refusedAtOnce
            }
        }
    }

    private static func firstToken(_ route: ServingRoute, _ frontEnd: ServingFrontEnd) -> RouteLimits.FirstToken {
        switch frontEnd {
        case .pair:
            switch route {
            // The owner's request waits for its first token unless the owner restored the allowance
            // (`DARKBLOOM_LOCAL_FIRST_TOKEN_WAIT=0`).
            case .owner(let wait): return wait.waitsForFirstToken ? .noAllowance : .pairAllowance
            case .coordinator, .ownerContinuation, .internal: return .pairAllowance
            }
        case .oneMac, .nemotronSuper:
            switch route {
            case .coordinator, .owner, .ownerContinuation, .internal: return .noAllowance
            }
        }
    }

    private static func requestDeadline(_ route: ServingRoute,
                                        _ frontEnd: ServingFrontEnd) -> RouteLimits.RequestDeadline {
        switch frontEnd {
        case .pair:
            switch route {
            case .owner, .ownerContinuation: return .protocolHour
            case .coordinator, .internal: return .setupRequestTimeout
            }
        case .oneMac, .nemotronSuper:
            switch route {
            case .coordinator, .owner, .ownerContinuation, .internal: return .enginesOwn
            }
        }
    }

    private static func context(_ route: ServingRoute, _ frontEnd: ServingFrontEnd) -> RouteLimits.Context {
        switch frontEnd {
        case .pair:
            switch route {
            case .owner, .ownerContinuation: return .pairOwnerServed
            case .coordinator, .internal: return .pairServed
            }
        case .oneMac, .nemotronSuper:
            switch route {
            case .coordinator, .owner, .ownerContinuation, .internal: return .modelWindow
            }
        }
    }
}

extension EngineV2Bridge {
    /// What serves this bridge's requests, as it was built: a pair's engine, or one Mac's own.
    nonisolated var servingFrontEnd: ServingFrontEnd { pairServedLimits == nil ? .oneMac : .pair }
}
