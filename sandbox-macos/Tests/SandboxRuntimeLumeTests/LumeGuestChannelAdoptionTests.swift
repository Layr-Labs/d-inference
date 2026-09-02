import Foundation
import SandboxCore
import SandboxRuntime
import XCTest

@testable import SandboxRuntimeLume

/// Adoption of the descriptor Lume patch 0005 hands over.
///
/// Before this existed, `receiveGuestChannelDescriptor()` was public with no
/// callers anywhere: the host created a channel and dropped it on the floor.
/// These cover the parts that leak or strand a file descriptor when wrong.
final class LumeGuestChannelAdoptionTests: XCTestCase {
    private func connectedPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw XCTSkip("socketpair unavailable")
        }
        return (pair[0], pair[1])
    }

    /// A descriptor is only closed deterministically if teardown closes it.
    /// Leaving it to ARC is not enough: `LumeGuestVsockTransport` is a struct
    /// holding a strong reference, so a transport still in flight can outlive
    /// the dictionary entry and hold the descriptor open past the VM's death.
    func testReleasingAChannelClosesTheDescriptor() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        let (host, guest) = try connectedPair()
        defer { close(guest) }

        let client = await runtime.adopt(descriptor: host, name: "vm-1")
        XCTAssertNotNil(client)
        let stored = await runtime.guestChannel(for: "vm-1")
        XCTAssertNotNil(stored)

        await runtime.releaseGuestChannel(name: "vm-1")

        let afterRelease = await runtime.guestChannel(for: "vm-1")
        XCTAssertNil(afterRelease)
        // The descriptor is really gone, not merely forgotten.
        XCTAssertEqual(fcntl(host, F_GETFL), -1)
        XCTAssertEqual(errno, EBADF)
    }

    /// A refused descriptor is handled cleanly rather than half-adopted.
    ///
    /// `SandboxGuestChannelClient.init` throws *before* storing the descriptor,
    /// so its `deinit` never runs and adoption closes it explicitly. That close
    /// is deliberately not asserted here: past the non-negative check the only
    /// way the initialiser throws is an `fcntl` failure, which in practice
    /// means the descriptor is already invalid, so the close is a no-op and
    /// unobservable. It is kept because a valid descriptor whose `F_SETFL`
    /// fails would otherwise leak for the life of the daemon. What this does
    /// prove is that the failure yields no client and stores nothing.
    func testAdoptionRefusesAnUnusableDescriptorCleanly() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        let (host, guest) = try connectedPair()
        close(guest)
        // Closing it first makes the client's fcntl fail, which is the only
        // way its initialiser throws after the non-negative check.
        close(host)

        let client = await runtime.adopt(descriptor: host, name: "vm-2")

        XCTAssertNil(client)
        let stored = await runtime.guestChannel(for: "vm-2")
        XCTAssertNil(stored, "a refused descriptor must not be stored")
    }

    func testReleasingAChannelThatNeverExistedIsHarmless() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        // Every teardown path calls this unconditionally, including the many
        // that run for VMs which never had a channel.
        await runtime.releaseGuestChannel(name: "never-existed")
        let stored = await runtime.guestChannel(for: "never-existed")
        XCTAssertNil(stored)
    }

    /// The agent serves many sequential commands on one connection and patch
    /// 0005 hands a descriptor over exactly once, so a second adoption must
    /// return the channel already held rather than expecting another.
    func testAdoptionIsIdempotentForOneVirtualMachine() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        let (host, guest) = try connectedPair()
        defer { close(guest) }

        let first = await runtime.adopt(descriptor: host, name: "vm-3")
        XCTAssertNotNil(first)
        let again = await runtime.guestChannel(for: "vm-3")
        XCTAssertTrue(first === again)

        await runtime.releaseGuestChannel(name: "vm-3")
    }

    /// The teardown wiring actually fires on the real stop path.
    ///
    /// A channel is closed at six separate places, because `stop` proves
    /// itself three different ways and failed starts unwind through two more.
    /// This drives a real start and stop through the fake Lume so a missing
    /// hook shows up as a descriptor that is still open afterwards, rather
    /// than as a leak nobody notices until a host runs out of files.
    func testStoppingAVirtualMachineReleasesItsChannel() async throws {
        let fixture = try FakeLumeFixture(
            behavior: "credentialed-readiness-start-intent"
        )
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime(
            commandTimeoutSeconds: 4,
            guestReadinessPolicy: LumeGuestReadinessPolicy(
                attemptTimeoutSeconds: 1,
                retryDelay: .milliseconds(10)
            )
        )

        try await runtime.start(name: fixture.virtualMachineName)

        // The fake Lume hands over no descriptor, so stand one in to prove the
        // teardown hook rather than the handover.
        let (host, guest) = try connectedPair()
        defer { close(guest) }
        _ = await runtime.adopt(
            descriptor: host, name: fixture.virtualMachineName
        )
        let before = await runtime.guestChannel(for: fixture.virtualMachineName)
        XCTAssertNotNil(before)

        try await runtime.stop(name: fixture.virtualMachineName)

        let after = await runtime.guestChannel(for: fixture.virtualMachineName)
        XCTAssertNil(after, "stop must forget the channel")
        XCTAssertEqual(
            fcntl(host, F_GETFL), -1,
            "stop must close the descriptor, not just forget it"
        )
    }

    /// Selection follows the channel, and falls back rather than failing.
    ///
    /// A VM has a channel only when this process spawned it and the image's
    /// baked agent bound its port, so an agentless or externally-started guest
    /// must keep working over SSH exactly as before.
    func testTransportFollowsTheChannelAndFallsBackToSSH() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()
        let credential = LumeGuestCredential.legacy

        let fallback = await runtime.guestCommandTransport(
            name: "vm-t", credential: credential
        )
        XCTAssertEqual(fallback.description, "lume ssh")

        let (host, guest) = try connectedPair()
        defer { close(guest) }
        _ = await runtime.adopt(descriptor: host, name: "vm-t")

        let selected = await runtime.guestCommandTransport(
            name: "vm-t", credential: credential
        )
        XCTAssertEqual(selected.description, "guest agent")

        // Another VM without a channel is unaffected.
        let other = await runtime.guestCommandTransport(
            name: "vm-u", credential: credential
        )
        XCTAssertEqual(other.description, "lume ssh")

        await runtime.releaseGuestChannel(name: "vm-t")
        // Once the channel is gone, so is the vsock selection.
        let afterRelease = await runtime.guestCommandTransport(
            name: "vm-t", credential: credential
        )
        XCTAssertEqual(afterRelease.description, "lume ssh")
    }

    /// Writes a handshake frame the way the real agent does.
    private func sendHandshake(
        on descriptor: Int32,
        imageID: String,
        agentVersion: String = "0.1.0",
        protocolVersion: Int = 1
    ) throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "magic": "darkbloom_guest_agent",
            "protocol_version": protocolVersion,
            "agent_version": agentVersion,
            "image_id": imageID,
        ])
        var frame = Data([1])                      // kind: handshake
        let length = UInt32(payload.count)
        frame.append(UInt8(truncatingIfNeeded: length >> 24))
        frame.append(UInt8(truncatingIfNeeded: length >> 16))
        frame.append(UInt8(truncatingIfNeeded: length >> 8))
        frame.append(UInt8(truncatingIfNeeded: length))
        frame.append(payload)
        try frame.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(descriptor, raw.baseAddress! + sent, raw.count - sent)
                guard n > 0 else { throw XCTSkip("socketpair write failed") }
                sent += n
            }
        }
    }

    /// A channel is only worth having if the peer proves it is our agent.
    func testAValidHandshakeKeepsTheChannel() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        let (host, guest) = try connectedPair()
        defer { close(guest) }
        try sendHandshake(on: guest, imageID: "base-image-7")

        let adopted = await runtime.adopt(descriptor: host, name: "vm-h")
        let client = try XCTUnwrap(adopted)
        let validated = await runtime.validate(
            client, name: "vm-h", expectedImageID: "base-image-7"
        )

        XCTAssertNotNil(validated)
        let stored = await runtime.guestChannel(for: "vm-h")
        XCTAssertNotNil(stored)
        await runtime.releaseGuestChannel(name: "vm-h")
    }

    /// An unverified channel is worse than none: it would be trusted for every
    /// command after this point. Dropping it falls back to SSH, which still has
    /// to pass its own readiness check.
    func testAMismatchedImageDropsTheChannel() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        let (host, guest) = try connectedPair()
        defer { close(guest) }
        try sendHandshake(on: guest, imageID: "some-other-image")

        let adopted = await runtime.adopt(descriptor: host, name: "vm-m")
        let client = try XCTUnwrap(adopted)
        let validated = await runtime.validate(
            client, name: "vm-m", expectedImageID: "base-image-7"
        )

        XCTAssertNil(validated)
        let stored = await runtime.guestChannel(for: "vm-m")
        XCTAssertNil(stored, "a channel that failed its handshake must not be kept")
        XCTAssertEqual(fcntl(host, F_GETFL), -1, "and its descriptor is closed")
    }

    /// Channels are per-VM, and releasing one must not disturb another.
    func testChannelsAreIsolatedPerVirtualMachine() async throws {
        let fixture = try FakeLumeFixture(initialState: "stopped")
        defer { try? fixture.remove() }
        let runtime = try fixture.makeRuntime()

        let (hostA, guestA) = try connectedPair()
        let (hostB, guestB) = try connectedPair()
        defer { close(guestA); close(guestB) }

        _ = await runtime.adopt(descriptor: hostA, name: "vm-a")
        _ = await runtime.adopt(descriptor: hostB, name: "vm-b")

        await runtime.releaseGuestChannel(name: "vm-a")

        let a = await runtime.guestChannel(for: "vm-a")
        let b = await runtime.guestChannel(for: "vm-b")
        XCTAssertNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(fcntl(hostA, F_GETFL), -1)
        XCTAssertNotEqual(fcntl(hostB, F_GETFL), -1)

        await runtime.releaseGuestChannel(name: "vm-b")
    }
}
