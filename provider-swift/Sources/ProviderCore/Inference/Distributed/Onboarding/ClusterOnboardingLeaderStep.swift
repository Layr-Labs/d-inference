import Foundation

// What the leading Mac's setup screen waits on, published in its status (`ClusterControlReply.step`) so the Mac that
// joined says it instead of a bare "Waiting for the other Mac" (a user's report, 2026-11-04: "an infinite loop of
// waiting for the other Mac, Apple M5 Max 128 GB"). Pure (Foundation only): the onboarding checks compile it.

/// The leading Mac's current setup step, as the Mac that joined reads it. An older leader publishes none.
public struct ClusterOnboardingLeaderStep: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Its Local Network prompt is up and not answered.
        case localNetwork
        /// It reads both Macs over the cable before it can list the models.
        case reading
        /// It could not read this Mac over the cable and asks Try again or Cancel.
        case tryAgain
        /// Its model list (or a model's mode question) is up.
        case modelList
        /// It asks how the chosen model reaches both Macs, or copies it.
        case copy
        /// It asks for a Darkbloom login.
        case login
        /// It sent the setup and starts both Macs.
        case starting
        /// It can't start any model on these Macs (`reason`); its window ended.
        case refused
        /// A step a later build adds: nothing is said for it.
        case unknown

        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var kind: Kind
    /// `refused`: why, in the leader's words.
    public var reason: String?
    /// The leading Mac's Darkbloom version, when it said it.
    public var version: String?

    public init(_ kind: Kind, reason: String? = nil, version: String? = nil) {
        self.kind = kind; self.reason = reason; self.version = version
    }

    /// The planner's blocker when the two Macs' cluster workers differ (`ClusterSetupPlanning.differentBuilds`).
    public static let differentBuildsReason = "the two Macs run different Darkbloom builds; install the same Darkbloom on both"

    /// The refusal of every model because the two Macs run different builds.
    public var differentBuilds: Bool { kind == .refused && reason == Self.differentBuildsReason }

    /// What the leading Mac is doing, after "the other Mac: "; nil when there is nothing to say.
    public var words: String? {
        switch kind {
        case .localNetwork: return "it's waiting for Allow on its Local Network prompt"
        case .reading: return "it's reading both Macs over the cable"
        case .tryAgain: return "it couldn't read this Mac over the cable and asks Try again"
        case .modelList: return "it's waiting for a model to be chosen on its screen"
        case .copy: return "it's asking how to get the model to both Macs"
        case .login: return "it's waiting for a Darkbloom login"
        case .starting: return "it's starting both Macs"
        case .refused: return "it can't start a model" + (reason.map { ": " + $0 } ?? "")
        case .unknown: return nil
        }
    }

    /// The same, short, for a narrow window.
    public var shortWords: String? {
        switch kind {
        case .localNetwork: return "Allow on its screen"
        case .reading: return "reading both Macs"
        case .tryAgain: return "Try again on its screen"
        case .modelList: return "model choice on its screen"
        case .copy: return "copy choice on its screen"
        case .login: return "login on its screen"
        case .starting: return "starting"
        case .refused: return "can't start a model"
        case .unknown: return nil
        }
    }

    /// Whether `version` is older than `other` ("0.10.8" < "0.10.9"); nil when either can't be read as numbers.
    public static func isOlder(_ version: String, than other: String) -> Bool? {
        func numbers(_ text: String) -> [Int]? {
            let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".").map { Int($0) }
            return parts.isEmpty || parts.contains(nil) ? nil : parts.compactMap { $0 }
        }
        guard let left = numbers(version), let right = numbers(other) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let (a, b) = (index < left.count ? left[index] : 0, index < right.count ? right[index] : 0)
            if a != b { return a < b }
        }
        return false
    }
}

/// The step as the leading Mac records it (`ClusterSetupRecord.onboardingStep`): it counts while the screen that set it
/// runs (its process, by pid and start time, so a pid the system gave to another process never counts). A refusal ends
/// that screen, so it counts for `refusalSeconds` after it was set instead, unless a later step replaced it.
public struct ClusterOnboardingLeaderStepMark: Codable, Sendable, Equatable {
    public var step: ClusterOnboardingLeaderStep
    public var pid: Int32
    /// When that process started (microseconds since 1970).
    public var started: UInt64
    /// When the step was set (seconds since 1970).
    public var at: Double

    public init(step: ClusterOnboardingLeaderStep, pid: Int32, started: UInt64, at: Double) {
        self.step = step; self.pid = pid; self.started = started; self.at = at
    }

    /// As long as the Mac that joined follows a start that never began (`ClusterOnboardingFollowTiming.seconds`), twice.
    public static let refusalSeconds: Double = 1_800

    /// The step, while it counts. `started`: when the process that has `pid` now started; nil when none runs.
    public func current(now: Double, started processStarted: (Int32) -> UInt64?) -> ClusterOnboardingLeaderStep? {
        if step.kind == .refused { return now - at < Self.refusalSeconds ? step : nil }
        return processStarted(pid) == started ? step : nil
    }
}

/// The leading Mac's status as the Mac that joined reads it: its lines and, from a build that publishes it, its step.
public struct ClusterOnboardingLeaderStatus: Sendable, Equatable {
    public var lines: [String]
    public var step: ClusterOnboardingLeaderStep?
    /// How far its start is (`ClusterOnboardingStartProgress`); nil before it starts, and from an older build.
    public var start: ClusterOnboardingStartProgress?
    public init(lines: [String], step: ClusterOnboardingLeaderStep?, start: ClusterOnboardingStartProgress? = nil) {
        self.lines = lines; self.step = step; self.start = start
    }
}
