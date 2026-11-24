import Foundation
import Testing
@testable import ProviderCore

/// Right after an update, a provider's first read of its own signature can fall in a window where the app bundle is
/// still changing. That read refuses the cluster helpers, but it must not stay the answer for the life of the
/// process: the next read is taken again, and a readable answer is kept from then on.
@Suite("The provider's own signature is read again until it is readable")
struct DistributedInstalledHelperSignatureKeptTests {
    final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [DistributedInstalledHelperSignature]
        private(set) var count = 0
        init(_ answers: [DistributedInstalledHelperSignature]) { self.answers = answers }
        func next() -> DistributedInstalledHelperSignature {
            lock.lock(); defer { lock.unlock() }
            count += 1
            return answers.isEmpty ? .unavailable : answers.removeFirst()
        }
    }

    static let signer = DistributedInstalledHelperSignature.Signer(
        leafSHA1: Data(repeating: 0xAB, count: 20), identifier: "io.darkbloom.provider",
        cdhash: Data(repeating: 0xCD, count: DistributedInstalledCodeDirectory.hashBytes), team: "SLDQ2GJ6TL")

    @Test("an unreadable signature is read again at the next access, then the readable answer is kept")
    func unreadableIsReadAgain() {
        let kept = DistributedInstalledHelperSignature.Kept()
        let reads = Reads([.unavailable, .unavailable, .signed(Self.signer), .unavailable])
        #expect(kept.value(reads.next) == .unavailable)
        #expect(kept.value(reads.next) == .unavailable)
        #expect(kept.value(reads.next) == .signed(Self.signer))
        // Kept: no further read, so a later unreadable answer can't replace it.
        #expect(kept.value(reads.next) == .signed(Self.signer))
        #expect(kept.value(reads.next) == .signed(Self.signer))
        #expect(reads.count == 3)
    }

    @Test("a build without this project's certificate is kept as unsigned after one read")
    func unsignedIsKept() {
        let kept = DistributedInstalledHelperSignature.Kept()
        let reads = Reads([.unsigned, .signed(Self.signer)])
        #expect(kept.value(reads.next) == .unsigned)
        #expect(kept.value(reads.next) == .unsigned)
        #expect(reads.count == 1)
    }

    @Test("while unreadable, every helper launch is still refused")
    func unreadableStillRefuses() {
        let kept = DistributedInstalledHelperSignature.Kept()
        let reads = Reads([.unavailable])
        let signature = kept.value(reads.next)
        #expect(throws: ClusterConfigurationError.self) {
            _ = try signature.ownerVerifier(URL(fileURLWithPath: "/bin/echo"))
        }
    }
}
