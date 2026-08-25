import Foundation

/// Builds the canonical `~/.darkbloom/bin` candidate without mutating the live
/// directory.
///
/// Every non-managed top-level entry is copied and content-verified. The four
/// managed names are then replaced only in the candidate. A symlink, regular
/// file, or other non-directory at the live `bin` path is never followed or
/// overwritten.
struct AppRelocationBinLayout {
    struct Candidate {
        let url: URL
        let previousState: AppRelocationArtifactState?
    }

    enum LayoutError: Error, LocalizedError {
        case invalidTransactionID(String)
        case candidateAlreadyExists(String)
        case unsafeLiveBin(path: String, kind: String)
        case liveBinChanged(String)
        case unmanagedEntriesChanged(String)
        case invalidCanonicalLink(path: String, expected: String)

        var errorDescription: String? {
            switch self {
            case .invalidTransactionID(let value):
                "The bin relocation transaction identifier is invalid: \(value)"
            case .candidateAlreadyExists(let path):
                "The bin relocation candidate path already exists: \(path)"
            case .unsafeLiveBin(let path, let kind):
                "Darkbloom refuses to replace \(path) because it is \(kind), not a real directory."
            case .liveBinChanged(let path):
                "The existing bin directory changed while Darkbloom copied it: \(path)"
            case .unmanagedEntriesChanged(let path):
                "Darkbloom could not prove that every unmanaged bin entry was preserved: \(path)"
            case .invalidCanonicalLink(let path, let expected):
                "The staged canonical link at \(path) does not point to \(expected)."
            }
        }
    }

    static let canonicalLinks: [(name: String, target: String)] = [
        ("darkbloom", "../Darkbloom.app/Contents/MacOS/darkbloom"),
        (
            "darkbloom-enclave",
            "../Darkbloom.app/Contents/MacOS/darkbloom-enclave"
        ),
        ("mlx.metallib", "../Darkbloom.app/Contents/MacOS/mlx.metallib"),
        ("eigeninference-enclave", "darkbloom-enclave"),
    ]

    static let candidatePrefix = ".bin.relocation-"

    private let installRoot: URL
    private let fileManager: FileManager

    init(
        installRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.installRoot = installRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    func prepareCandidate(transactionID: String) throws -> Candidate {
        guard let uuid = UUID(uuidString: transactionID),
              uuid.uuidString.lowercased() == transactionID
        else {
            throw LayoutError.invalidTransactionID(transactionID)
        }

        let candidate = installRoot.appendingPathComponent(
            "\(Self.candidatePrefix)\(transactionID)",
            isDirectory: true
        )
        guard !AppRelocationFilesystem.itemExists(candidate) else {
            throw LayoutError.candidateAlreadyExists(candidate.path)
        }

        let live = installRoot.appendingPathComponent("bin", isDirectory: true)
        let previousState: AppRelocationArtifactState?
        switch try AppRelocationFilesystem.pathKind(at: live) {
        case nil:
            previousState = nil
            try fileManager.createDirectory(
                at: candidate,
                withIntermediateDirectories: false
            )
        case .directory:
            previousState = try AppRelocationFilesystem.synchronizedState(at: live)
            try fileManager.copyItem(at: live, to: candidate)
        case .symbolicLink:
            throw LayoutError.unsafeLiveBin(
                path: live.path,
                kind: "a symbolic link"
            )
        case .regularFile:
            throw LayoutError.unsafeLiveBin(
                path: live.path,
                kind: "a regular file"
            )
        case .unsupported(let mode):
            throw LayoutError.unsafeLiveBin(
                path: live.path,
                kind: "an unsupported filesystem object (mode \(mode))"
            )
        }

        try installCanonicalLinks(in: candidate)
        try verifyCanonicalLinks(in: candidate)

        if let previousState {
            guard try AppRelocationFilesystem.state(at: live) == previousState else {
                throw LayoutError.liveBinChanged(live.path)
            }
            try verifyUnmanagedEntriesPreserved(from: live, in: candidate)
        }
        return Candidate(url: candidate, previousState: previousState)
    }

    private func installCanonicalLinks(in candidate: URL) throws {
        for link in Self.canonicalLinks {
            let path = candidate.appendingPathComponent(link.name)
            if AppRelocationFilesystem.itemExists(path) {
                try fileManager.removeItem(at: path)
            }
            try fileManager.createSymbolicLink(
                atPath: path.path,
                withDestinationPath: link.target
            )
        }
    }

    private func verifyCanonicalLinks(in candidate: URL) throws {
        guard try AppRelocationFilesystem.pathKind(at: candidate) == .directory else {
            throw LayoutError.unsafeLiveBin(
                path: candidate.path,
                kind: "an invalid candidate"
            )
        }
        for link in Self.canonicalLinks {
            let path = candidate.appendingPathComponent(link.name)
            guard try AppRelocationFilesystem.pathKind(at: path) == .symbolicLink,
                  try fileManager.destinationOfSymbolicLink(atPath: path.path)
                    == link.target
            else {
                throw LayoutError.invalidCanonicalLink(
                    path: path.path,
                    expected: link.target
                )
            }
        }
    }

    private func verifyUnmanagedEntriesPreserved(
        from live: URL,
        in candidate: URL
    ) throws {
        let managedNames = Set(Self.canonicalLinks.map(\.name))
        let liveEntries = try unmanagedEntries(in: live, excluding: managedNames)
        let candidateEntries = try unmanagedEntries(
            in: candidate,
            excluding: managedNames
        )
        guard Set(liveEntries.keys) == Set(candidateEntries.keys) else {
            throw LayoutError.unmanagedEntriesChanged(live.path)
        }

        for name in liveEntries.keys.sorted() {
            guard let source = liveEntries[name],
                  let copy = candidateEntries[name],
                  try AppRelocationFilesystem.state(at: source).contentHash
                    == AppRelocationFilesystem.state(at: copy).contentHash
            else {
                throw LayoutError.unmanagedEntriesChanged(
                    live.appendingPathComponent(name).path
                )
            }
        }
    }

    private func unmanagedEntries(
        in directory: URL,
        excluding managedNames: Set<String>
    ) throws -> [String: URL] {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        return Dictionary(
            uniqueKeysWithValues: entries.compactMap { entry in
                let name = entry.lastPathComponent
                return managedNames.contains(name) ? nil : (name, entry)
            }
        )
    }
}
