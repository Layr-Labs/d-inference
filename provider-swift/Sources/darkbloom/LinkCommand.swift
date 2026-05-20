import Foundation
import ArgumentParser
import ProviderCore
import Network

/// darkbloom link — high-throughput peer-to-peer transport over Thunderbolt 5.
///
/// Usage:
///   Mac A (receive):  darkbloom link --listen
///   Mac B (send):     darkbloom link --connect 192.168.100.1 --bytes 4294967296
///
/// Prerequisites on both Macs:
///   sudo sysctl -w kern.ipc.maxsockbuf=268435456
///   sudo sysctl -w net.inet.tcp.sendspace=33554432
///   sudo sysctl -w net.inet.tcp.recvspace=33554432
///   sudo ifconfig bridge100 192.168.100.1 255.255.255.0   # Mac A
///   sudo ifconfig bridge100 192.168.100.2 255.255.255.0   # Mac B
///
/// Find the Thunderbolt interface name:
///   networksetup -listallhardwareports | grep -A2 -i thunderbolt
struct Link: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "High-throughput Thunderbolt 5 peer-to-peer transport."
    )

    @Flag(name: .shortAndLong, help: "Listen for an incoming connection (receiver mode).")
    var listen = false

    @Option(name: .shortAndLong, help: "IP address of the listening peer (sender mode).")
    var connect: String?

    @Option(name: .shortAndLong, help: "Port to listen on or connect to.")
    var port: UInt16 = ThunderboltLink.defaultPort

    @Option(name: .long, help: "Number of bytes to send in benchmark mode (sender only).")
    var bytes: UInt64 = 4 * 1024 * 1024 * 1024   // 4 GB default

    @Option(name: .long, help: "Chunk size in bytes for the sender loop.")
    var chunkSize: Int = 4 * 1024 * 1024           // 4 MB default

    mutating func validate() throws {
        guard listen || connect != nil else {
            throw ValidationError("Specify --listen (receiver) or --connect <host> (sender).")
        }
        guard !(listen && connect != nil) else {
            throw ValidationError("--listen and --connect are mutually exclusive.")
        }
    }

    mutating func run() async throws {
        if listen {
            try await runReceiver()
        } else if let host = connect {
            try await runSender(host: host)
        }
    }

    // MARK: - Receiver

    private func runReceiver() async throws {
        print("Listening on port \(port)…")
        print("(ensure: sudo sysctl -w kern.ipc.maxsockbuf=268435456)")

        // Stream connections so we can await the first one.
        let (stream, continuation) = AsyncStream<ThunderboltConnection>.makeStream()

        let listener = try ThunderboltLink.listen(on: port) { conn in
            continuation.yield(conn)
        }

        guard let conn = await stream.first(where: { _ in true }) else {
            listener.cancel()
            throw ExitCode.failure
        }
        continuation.finish()

        print("Peer connected.")

        // Read 8-byte header: total expected bytes.
        let headerData = try await conn.receive()
        guard headerData.count == 8 else {
            print("Bad header — expected 8 bytes, got \(headerData.count)")
            conn.cancel()
            listener.cancel()
            return
        }
        let totalExpected = headerData.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        print(String(format: "Expecting %.2f GB (%llu bytes)…", Double(totalExpected) / 1_073_741_824, totalExpected))

        var received: UInt64 = 0
        let t0 = Date()
        var lastPrint = t0

        for try await chunk in conn.receiveStream() {
            received += UInt64(chunk.count)

            let now = Date()
            if now.timeIntervalSince(lastPrint) >= 1.0 {
                let elapsed = now.timeIntervalSince(t0)
                let gbps = Double(received) * 8.0 / elapsed / 1e9
                print(String(format: "  %.2f GB received  %.2f Gbps", Double(received) / 1_073_741_824, gbps))
                lastPrint = now
            }

            if received >= totalExpected { break }
        }

        let elapsed = Date().timeIntervalSince(t0)
        let gbps = Double(received) * 8.0 / elapsed / 1e9
        print(String(format: "\nDone. Received %llu bytes in %.3f s → %.2f Gbps", received, elapsed, gbps))

        // Acknowledge.
        var ack = received.littleEndian
        let ackData = Swift.withUnsafeBytes(of: &ack) { Data($0) }
        try await conn.send(ackData)

        conn.cancel()
        listener.cancel()
    }

    // MARK: - Sender

    private func runSender(host: String) async throws {
        print("Connecting to \(host):\(port)…")
        print("(ensure: sudo sysctl -w kern.ipc.maxsockbuf=268435456)")

        let conn = try await ThunderboltLink.connect(to: host, port: port)
        print("Connected.")

        // Send 8-byte header with total byte count.
        var totalLE = bytes.littleEndian
        let header = Swift.withUnsafeBytes(of: &totalLE) { Data($0) }
        try await conn.send(header)

        // Allocate one chunk buffer filled with non-zero data.
        let chunk = Data(repeating: 0xAB, count: chunkSize)

        var sent: UInt64 = 0
        let t0 = Date()
        var lastPrint = t0

        while sent < bytes {
            let remaining = bytes - sent
            let payload = remaining >= UInt64(chunkSize) ? chunk : Data(chunk.prefix(Int(remaining)))
            try await conn.send(payload)
            sent += UInt64(payload.count)

            let now = Date()
            if now.timeIntervalSince(lastPrint) >= 1.0 {
                let elapsed = now.timeIntervalSince(t0)
                let gbps = Double(sent) * 8.0 / elapsed / 1e9
                print(String(format: "  %.2f GB sent  %.2f Gbps", Double(sent) / 1_073_741_824, gbps))
                lastPrint = now
            }
        }

        let elapsed = Date().timeIntervalSince(t0)
        let gbps = Double(sent) * 8.0 / elapsed / 1e9
        print(String(format: "\nSent %llu bytes in %.3f s → %.2f Gbps", sent, elapsed, gbps))

        // Wait for ACK.
        let ackData = try await conn.receive()
        if ackData.count == 8 {
            let confirmed = ackData.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
            print("Receiver confirmed \(confirmed) bytes.")
        }

        conn.cancel()
    }
}
