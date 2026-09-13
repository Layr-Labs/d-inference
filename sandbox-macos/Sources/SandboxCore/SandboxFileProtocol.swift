import Foundation

public enum SandboxWireFileOperationKind: String, Codable, CaseIterable, Sendable {
    case uploadBegin = "upload_begin"
    case uploadChunk = "upload_chunk"
    case uploadStatus = "upload_status"
    case uploadCommit = "upload_commit"
    case uploadAbort = "upload_abort"
    case download
    case mkdir
}

public struct SandboxWireFileOperation: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let scope: SandboxWireScope
    public let operation: SandboxWireFileOperationKind
    public let transferID: UUID?
    public let path: String?
    public let offset: UInt64?
    public let size: UInt64?
    public let sha256: String?
    public let data: Data?
    public let version: String?

    public init(requestID: UUID, scope: SandboxWireScope, operation: SandboxWireFileOperationKind,
                transferID: UUID? = nil, path: String? = nil, offset: UInt64? = nil,
                size: UInt64? = nil, sha256: String? = nil, data: Data? = nil, version: String? = nil) {
        self.requestID = requestID; self.scope = scope; self.operation = operation
        self.transferID = transferID; self.path = path; self.offset = offset
        self.size = size; self.sha256 = sha256; self.data = data
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case scope, operation
        case transferID = "transfer_id"
        case path, offset, size, sha256, data, version
    }
}

public struct SandboxWireFileResult: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let scope: SandboxWireScope
    public let operation: SandboxWireFileOperationKind
    public let success: Bool
    public let errorCode: String?
    public let transferID: UUID?
    public let state: String?
    public let offset: UInt64?
    public let size: UInt64?
    public let sha256: String?
    public let data: Data?
    public let version: String?

    public init(requestID: UUID, scope: SandboxWireScope, operation: SandboxWireFileOperationKind,
                success: Bool, errorCode: String? = nil, transferID: UUID? = nil,
                state: String? = nil, offset: UInt64? = nil, size: UInt64? = nil,
                sha256: String? = nil, data: Data? = nil, version: String? = nil) {
        self.requestID = requestID; self.scope = scope; self.operation = operation
        self.success = success; self.errorCode = errorCode; self.transferID = transferID
        self.state = state; self.offset = offset; self.size = size; self.sha256 = sha256; self.data = data
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case scope, operation, success
        case errorCode = "error_code"
        case transferID = "transfer_id"
        case state, offset, size, sha256, data, version
    }
}

public enum SandboxFileWireValidation {
    public static let maximumChunkBytes = 512 * 1024
    public static let maximumFileBytes: UInt64 = 50 * 1024 * 1024 * 1024

    public static func validPath(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty && value.utf8.count <= 4096 && !value.hasPrefix("/")
            && !value.contains("\0") && parts.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
            }
    }

    public static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    public static func validate(_ value: SandboxWireFileOperation) -> Bool {
        if let version = value.version {
            guard value.operation == .download, validDigest(version) else { return false }
        }
        guard value.path.map(validPath) ?? true,
              value.sha256.map(validDigest) ?? true,
              value.size.map({ $0 <= maximumFileBytes }) ?? true,
              value.offset.map({ $0 <= maximumFileBytes }) ?? true else { return false }
        switch value.operation {
        case .uploadBegin:
            return value.transferID != nil && value.path != nil && value.size != nil && value.sha256 != nil
                && value.offset == nil && value.data == nil
        case .uploadChunk:
            guard value.transferID != nil, let offset = value.offset, let data = value.data,
                  !data.isEmpty, data.count <= maximumChunkBytes,
                  UInt64(data.count) <= maximumFileBytes - offset else { return false }
            return value.path == nil && value.size == nil && value.sha256 == nil
        case .uploadStatus, .uploadCommit, .uploadAbort:
            return value.transferID != nil && value.path == nil && value.size == nil && value.sha256 == nil
                && value.offset == nil && value.data == nil
        case .download:
            guard value.path != nil, value.offset != nil, let size = value.size,
                  size > 0 && size <= UInt64(maximumChunkBytes) else { return false }
            if value.offset != 0 && value.version == nil { return false }
            return value.transferID == nil && value.data == nil && value.sha256 == nil
        case .mkdir:
            return value.path != nil && value.transferID == nil && value.size == nil && value.sha256 == nil
                && value.offset == nil && value.data == nil
        }
    }
}
