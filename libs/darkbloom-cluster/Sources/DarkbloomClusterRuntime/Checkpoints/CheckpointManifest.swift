import Foundation

struct CheckpointManifest: Codable {
    struct Entry: Codable {
        let path: String
        let sha256: String
        let size_bytes: Int
    }
    let aggregate_sha256: String
    let file_count: Int
    let total_size_bytes: Int
    let files: [Entry]
}
