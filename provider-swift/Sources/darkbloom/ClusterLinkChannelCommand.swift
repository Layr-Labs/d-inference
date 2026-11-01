import ArgumentParser
import Foundation
import ProviderCore

extension Cluster {
    /// Qualification of the link control channel with the listener inside
    /// this provider binary. Hidden: not a user command. The edge secret is
    /// read from standard input (one hex line); there is no option for it.
    struct LinkChannel: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "link-channel",
            abstract: "Qualify the link control channel over the Thunderbolt link (secret on standard input).",
            shouldDisplay: false, subcommands: [Listen.self, Probe.self])

        struct Common: ParsableArguments {
            @Option(help: "Interface to bind, such as en7 or bridge0.") var interface: String?
            @Option(help: "RDMA device of the link, such as rdma_en7; picks the interface that carries its IPv4.") var device: String?
            @Option(name: .customLong("local-address"), help: "IPv4 address on the interface to bind.") var localAddress: String?
            @Option(name: .customLong("peer-address"), help: "IPv4 address of the other Mac on the link.") var peerAddress: String?
            @Option(help: "TCP port.") var port: Int = 47_420
            @Option(help: "Epoch UUID shared by both ends.") var epoch: String
            @Option(help: "Edge UUID shared by both ends.") var edge: String
            @Flag(name: .customLong("loopback-for-tests"), help: "Use loopback (one-Mac test only).") var loopback = false
            @Option(name: .customLong("heartbeat-ms")) var heartbeatMilliseconds: Int?
            @Option(name: .customLong("silence-ms")) var silenceMilliseconds: Int?

            func request() -> ClusterLinkChannelQualificationRequest {
                var request = ClusterLinkChannelQualificationRequest(epoch: epoch, edge: edge)
                request.interface = interface; request.device = device
                request.localAddress = localAddress; request.peerAddress = peerAddress; request.port = port
                request.loopbackForTests = loopback
                request.heartbeatMilliseconds = heartbeatMilliseconds; request.silenceMilliseconds = silenceMilliseconds
                return request
            }
        }

        struct Listen: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "listen",
                abstract: "Listen inside this provider process until standard input closes.")
            @OptionGroup var common: Common
            @Option(help: "Maximum lifetime in seconds.") var seconds: Double = 600

            mutating func run() throws {
                var request = common.request()
                request.seconds = seconds
                let summary = try ClusterLinkControlHost.qualificationListen(request, output: LinkChannel.emit)
                LinkChannel.emit("SUMMARY " + summary)
            }
        }

        struct Probe: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "probe",
                abstract: "Connect, measure round trips and throughput, optionally keep sending through a restart.")
            @OptionGroup var common: Common
            @Option var pings: Int = 2000
            @Option var spaced: Int = 300
            @Option(help: "Comma-separated gaps in microseconds for spaced pings.") var gaps: String = "1000,10000"
            @Option var typed: Int = 500
            @Option(name: .customLong("bulk-frames")) var bulkFrames: Int = 256
            @Option(name: .customLong("bulk-bytes")) var bulkBytes: Int = 1 << 20
            @Flag(name: .customLong("no-reverse")) var noReverse = false
            @Option(name: .customLong("resume-seconds")) var resumeSeconds: Double = 0
            @Option(name: .customLong("connect-seconds")) var connectSeconds: Double = 20

            mutating func run() throws {
                var request = common.request()
                request.pings = pings; request.spacedPings = spaced
                request.gapsMicroseconds = gaps.split(separator: ",").compactMap { UInt32($0) }
                request.typedEchoes = typed; request.bulkFrames = bulkFrames; request.bulkFrameBytes = bulkBytes
                request.reverseBulk = !noReverse; request.resumeSeconds = resumeSeconds; request.connectSeconds = connectSeconds
                let result = try ClusterLinkControlHost.qualificationProbe(request, output: LinkChannel.emit)
                LinkChannel.emit("SUMMARY " + result.json)
                if !result.measured { throw ExitCode(2) }
            }
        }

        @Sendable static func emit(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }
}
