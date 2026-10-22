import Foundation

/// Source-bound selection of the SAME full-bank SwitchGLU/GatherQMM route.
/// CPU route metadata only. No numerical tolerance or tensor observation.
struct ExpertAxisProjectionPolicy: Encodable, Equatable {
    let globalAssignments: Int, globalExperts: Int, ownedExperts: Int, localAssignments: Int
    let sortAssignments: Bool, sortedProjection: Bool
    let executedAssignments: Int
    var paddedAssignments: Int { executedAssignments - localAssignments }

    init(globalAssignments: Int, globalExperts: Int, ownedExperts: Int, localAssignments: Int) throws {
        guard (1...ExpertAxisQualificationLimits.maximumAssignments).contains(globalAssignments), (2...128).contains(globalExperts),
              (1...globalExperts).contains(ownedExperts), (0...globalAssignments).contains(localAssignments) else {
            throw ProbeError("Expert projection policy geometry is outside the bounded route")
        }
        self.globalAssignments = globalAssignments; self.globalExperts = globalExperts
        self.ownedExperts = ownedExperts; self.localAssignments = localAssignments
        sortAssignments = globalAssignments >= 64
        // Pinned GatherQMM: M=1, B>=16, sorted hint, integer B/E>=4.
        sortedProjection = sortAssignments && globalAssignments / globalExperts >= 4
        guard localAssignments > 0, sortedProjection else {
            executedAssignments = localAssignments; return
        }
        // Pinned NAX sorted-RHS tile: BM32 if M/E<64, otherwise BM64.
        // Match its row-alignment specialization too (also fixes legacy BM16).
        let tile = globalAssignments / globalExperts < 64 ? 32 : 64
        let minimum = max(localAssignments, max(16, max(4 * ownedExperts,
                          tile == 64 ? 64 * ownedExperts : 0)))
        let padding = (globalAssignments % tile - minimum % tile + tile) % tile
        let executed = minimum + padding
        guard executed <= globalAssignments,
              (executed / ownedExperts < 64 ? 32 : 64) == tile else {
            throw ProbeError("Owned expert density cannot retain the full-bank sorted kernel tile")
        }
        executedAssignments = executed
    }

    /// Repeats only this rank's final genuine assignment; these discarded
    /// projection rows never enter a returned packet or top-k reduction.
    func padded<T>(_ original: [T]) throws -> [T] {
        guard original.count == localAssignments else {
            throw ProbeError("Expert policy does not match the actual local assignment count")
        }
        guard paddedAssignments > 0 else { return original }
        guard let last = original.last else { throw ProbeError("Empty expert rank cannot be padded") }
        return original + Array(repeating: last, count: paddedAssignments)
    }
}
