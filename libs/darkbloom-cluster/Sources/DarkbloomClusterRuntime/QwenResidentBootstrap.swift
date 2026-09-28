import DarkbloomClusterBootstrap
import Foundation

/// An explicitly attached local owner channel. The owner must supply the
/// authenticated peer relay; a local socket alone does not establish that trust.
public struct QwenResidentBootstrap: Sendable {
    private let connection: ClusterBootstrapConnection
    public init(connection: ClusterBootstrapConnection) { self.connection = connection }

    func make(configuration: QwenResidentLoadConfiguration) throws -> JACCLBootstrap {
        guard connection.identity.membershipEpoch == configuration.identity.membershipEpoch,
              connection.identity.rank == configuration.rank,
              connection.deadlineUptimeNanoseconds <= configuration.deadlineUptimeNanoseconds else {
            throw ProbeError("Bootstrap attachment differs from resident identity or lifetime")
        }
        return try JACCLBootstrap(membershipEpoch: connection.identity.membershipEpoch, rank: connection.identity.rank) {
            epoch, rank, size, sequence, data, expectedBytes in
            guard epoch == connection.identity.membershipEpoch, rank == connection.identity.rank,
                  size == 2, expectedBytes == data.count * 2 else {
                throw ClusterBootstrapError.invalid("Native bootstrap shape differs")
            }
            return try connection.exchange(sequence: sequence, contribution: data)
        }
    }
}
