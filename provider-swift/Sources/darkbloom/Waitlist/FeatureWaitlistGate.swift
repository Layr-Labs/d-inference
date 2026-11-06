import ArgumentParser
import Foundation
import ProviderCore

/// The approval a first setup of a feature needs: `sandbox setup` and
/// `cluster` set up something new only for an account Darkbloom approved from
/// the feature's waitlist. Each outcome:
///
/// - approved: setup goes on;
/// - the coordinator has no such waitlist (404, as one released before
///   waitlists answers): setup goes on, after one line that says so;
/// - not on the waitlist: setup offers to join it, then treats the join's
///   answer the same way; declined, or without a way to ask, it prints the
///   join command and stops;
/// - waitlisted or revoked: setup shows where the account stands and stops;
/// - not logged in (401) or refused (403): setup says to log in and stops;
/// - no usable answer (unreachable, timeout, another answer): setup says why,
///   says to try again, and stops.
///
/// Every stop changes nothing and exits 1.
struct FeatureWaitlistGate {
    /// The waitlist's id in the coordinator's catalog, such as `cluster`.
    let feature: String
    /// Names the waitlist when the coordinator gave no answer; an answer
    /// brings the coordinator's own title.
    let fallbackTitle: String
    /// The setup command, for the lines that say to run it again.
    let setupCommand: String
    /// What a stop left as it was, such as `Nothing was installed.`
    let unchanged: String
    let access: FeatureWaitlistAccess
    /// Joins without asking (`--yes`).
    var joinWithoutAsking = false
    /// Asks the question at a prompt; nil without one.
    var ask: ((String) -> Bool)?
    /// A last line for every stop, such as what works without the approval.
    var stopNote: String?
    var say: (String) -> Void = { print($0) }
    var warn: (String) -> Void = { printError($0) }

    func require() async throws {
        let view = FeatureWaitlistView(cli: BuildEnvironment.current.cliName, coordinator: access.coordinator)
        var title = fallbackTitle
        var lookup = await access.place(feature)
        if case .success(let place) = lookup, place.status == .none {
            title = place.title
            let shown = FeatureWaitlistView.printable(title)
            say("\(shown) is open to the accounts Darkbloom approves from its waitlist.")
            guard joinWithoutAsking || ask?("Join the \(shown) waitlist now?") == true else {
                say(view.joinLine(feature))
                if let stopNote { say(stopNote) }
                throw ExitCode.failure
            }
            lookup = await access.join(feature)
        }
        switch lookup {
        case .failure(.notOffered):
            say("\(access.coordinator) has no \(FeatureWaitlistView.printable(title)) waitlist; going on.")
        case .success(let place):
            guard place.status != .approved else { return }
            view.lines(place, name: feature).forEach(say)
            if place.status == .waitlisted {
                say("  \(unchanged) Run `\(setupCommand)` again once Darkbloom approves your account.")
            }
            if let stopNote { say(stopNote) }
            throw ExitCode.failure
        case .failure(let problem):
            view.problem(problem, title: title).forEach(warn)
            if case .unavailable = problem {
                warn("  \(unchanged) Check this Mac's network and run `\(setupCommand)` again.")
            }
            if let stopNote { warn(stopNote) }
            throw ExitCode.failure
        }
    }
}
