import Foundation

/// The transition logic behind `cluster link --watch`: previous report, new
/// report, events. No timer, signal or child process is involved.
extension ClusterLinkCheck {
    private typealias Event = ClusterLinkWatchEvent

    private static func events(_ previous: FakeLinkTools?, _ current: FakeLinkTools) -> [Event] {
        ClusterLinkWatch.events(previous: previous?.inspect().report, current: current.inspect().report)
    }

    static func watchReducer() {
        var down = FakeLinkTools.macB, disabled = FakeLinkTools.macA
        down.deviceList = .output(LinkFixtures.deviceList(active: nil))
        disabled.controlStatus = .output("disabled\n")
        let bridged = ClusterLinkReadinessState.portBridgedWithoutAddress

        let startedReady = events(nil, .macA)
        expectEqual(startedReady, [Event(event: .started, state: .ready, previousState: nil, device: nil, interface: nil,
            verdict: nil, fixable: false, guidance: nil)], "first poll on a ready Mac")
        expectEqual(startedReady.flatMap(\.lines), ["Local link: ready"], "first line on a ready Mac")

        let startedBlocked = events(nil, .macB)
        expectEqual(startedBlocked, [Event(event: .started, state: bridged, previousState: nil, device: nil, interface: nil,
            verdict: nil, fixable: true, guidance: bridged.guidance)], "first poll on a blocked Mac")
        expectEqual(startedBlocked.flatMap(\.lines), ["Local link: portBridgedWithoutAddress", bridged.guidance ?? "?"],
            "a fixable state brings its guidance")
        expectEqual(events(nil, disabled).flatMap(\.lines), ["Local link: rdmaDisabled"], "a state the fix cannot change brings none")

        expectEqual(events(.macA, .macA), [], "nothing changed")
        expectEqual(events(.macB, .macB), [], "nothing changed while blocked")

        // The cable is plugged in: the port comes up, then the state follows.
        let plugged = events(down, .macB)
        expectEqual(plugged, [
            Event(event: .portUp, state: bridged, previousState: nil, device: "rdma_en6", interface: "en6", verdict: bridged,
                fixable: true, guidance: nil),
            Event(event: .stateChanged, state: bridged, previousState: .noActivePort, device: nil, interface: nil, verdict: nil,
                fixable: true, guidance: bridged.guidance)], "cable plugged in")
        expectEqual(plugged.flatMap(\.lines), ["Port up: rdma_en6 (en6) · portBridgedWithoutAddress",
            "Local link: portBridgedWithoutAddress (was noActivePort)", bridged.guidance ?? "?"], "cable plugged in, as text")

        // The fix lands: the port stays up and only the state moves.
        let repaired = events(.macB, .macBFixed())
        expectEqual(repaired, [Event(event: .stateChanged, state: .ready, previousState: bridged, device: nil, interface: nil,
            verdict: nil, fixable: false, guidance: nil)], "address added")
        expectEqual(repaired.flatMap(\.lines), ["Local link: ready (was portBridgedWithoutAddress)"], "address added, as text")

        let unplugged = events(.macA, down)
        expectEqual(unplugged.map(\.event), [.portDown, .stateChanged], "cable unplugged")
        expectEqual(unplugged.flatMap(\.lines), ["Port down: rdma_en7 (en7)", "Local link: noActivePort (was ready)"],
            "cable unplugged, as text")
        expectEqual(unplugged.first?.verdict, .noActivePort, "a port that went down carries its new verdict")

        // A device that leaves the listing was up and is not any more.
        expectEqual(events(.macA, disabled).flatMap(\.lines), ["Port down: rdma_en7 (en7)", "Local link: rdmaDisabled (was ready)"],
            "RDMA turned off")
        expectEqual(events(disabled, .macA).flatMap(\.lines), ["Port up: rdma_en7 (en7) · ready", "Local link: ready (was rdmaDisabled)"],
            "RDMA turned on")

        // Several ports change in one poll: listing order, state last.
        let swapped = events(.macA, .macB)
        expectEqual(swapped.map(\.event), [.portUp, .portDown, .stateChanged], "one port up and another down")
        expectEqual(swapped.compactMap(\.device), ["rdma_en6", "rdma_en7"], "ports in listing order")

        for event in startedBlocked + plugged + repaired + unplugged {
            let line = compactJSON(event)
            expect(!line.contains("\n") && line.hasPrefix("{") && line.hasSuffix("}"), "\(event.event) is one JSON line")
            expect(line.contains("\"schema\":\"darkbloom_cluster_link_watch_v1\"") && line.contains("\"event\":\"\(event.event.rawValue)\"")
                && line.contains("\"state\":\"\(event.state.rawValue)\""), "\(event.event) JSON identity")
            expectNoAddress(line + event.lines.joined(), "\(event.event) output")
        }
        let portLine = plugged.first.map { compactJSON($0) } ?? "", stateLine = plugged.last.map { compactJSON($0) } ?? ""
        expect(portLine.contains("\"device\":\"rdma_en6\"") && portLine.contains("\"fixable\":true"), "port event JSON names the port")
        expect(stateLine.contains("\"previousState\":\"noActivePort\"") && stateLine.contains("--fix"),
            "state event JSON carries the previous state and the fix guidance")
    }
}
