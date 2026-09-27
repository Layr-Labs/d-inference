import Foundation

extension ModelCatalogClient {
    private static let maximumManifestFileCount = 16_384
    private static let maximumJSONNestingDepth = 32
    private static let maximumJSONStringBytes = 256 * 1024
    private static let maximumJSONCollectionCount = 4_096

    /// Cheap lexical limits run before recursive Codable decoding. They are
    /// deliberately not a JSON parser; malformed syntax still belongs to
    /// JSONDecoder, while depth and individual string size are bounded here.
    static func validateJSONLexicalBounds(
        _ data: Data,
        responseName: String
    ) throws {
        var depth = 0
        var inString = false
        var escaped = false
        var stringBytes = 0

        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                    stringBytes = 0
                } else {
                    stringBytes += 1
                    if stringBytes > maximumJSONStringBytes {
                        throw ModelCatalogError.decodeFailed(
                            "\(responseName) contains an oversized JSON string")
                    }
                }
                continue
            }

            switch byte {
            case 0x22:
                inString = true
                stringBytes = 0
            case 0x7b, 0x5b:
                depth += 1
                if depth > maximumJSONNestingDepth {
                    throw ModelCatalogError.decodeFailed(
                        "\(responseName) exceeds JSON nesting bound")
                }
            case 0x7d, 0x5d:
                depth = max(0, depth - 1)
            default:
                break
            }
        }
    }

    static func validateCatalogBounds(_ response: CatalogResponse) throws {
        guard response.models.count <= maximumCatalogModelCount else {
            throw ModelCatalogError.decodeFailed("catalog model count exceeds provider bound")
        }
        let aliases = response.aliases ?? []
        guard aliases.count <= maximumCatalogAliasCount else {
            throw ModelCatalogError.decodeFailed("catalog alias count exceeds provider bound")
        }
        guard response.models.allSatisfy(modelWithinBounds),
            aliases.allSatisfy(aliasWithinBounds)
        else {
            throw ModelCatalogError.decodeFailed("catalog field exceeds provider structural bound")
        }
    }

    private static func modelWithinBounds(_ model: CatalogModel) -> Bool {
        let strings = [
            model.id, model.s3Name, model.displayName, model.modelType,
            model.architecture, model.description, model.weightHash, model.version,
            model.r2Prefix, model.aggregateSHA256, model.family, model.quantization,
            model.huggingFaceArtifact?.repoID, model.huggingFaceArtifact?.revision,
            model.huggingFaceArtifact?.pathPrefix,
        ].compactMap { $0 }
        guard strings.allSatisfy({ $0.utf8.count <= maximumJSONStringBytes }),
            (model.capabilities?.count ?? 0) <= maximumJSONCollectionCount,
            model.capabilities?.allSatisfy({ $0.utf8.count <= maximumJSONStringBytes }) ?? true,
            jsonDictionaryWithinBounds(model.runtimeParameters),
            jsonDictionaryWithinBounds(model.metadata)
        else { return false }
        return true
    }

    private static func aliasWithinBounds(_ alias: CatalogAlias) -> Bool {
        let strings = [
            alias.id, alias.displayName, alias.desiredBuild,
            alias.previousBuild, alias.primaryBuild,
        ].compactMap { $0 }
        return strings.allSatisfy { $0.utf8.count <= maximumJSONStringBytes }
            && (alias.retiredBuilds?.count ?? 0) <= maximumJSONCollectionCount
            && (alias.retiredBuilds?.allSatisfy {
                $0.utf8.count <= maximumJSONStringBytes
            } ?? true)
    }

    private static func jsonDictionaryWithinBounds(
        _ dictionary: [String: JSONValue]?
    ) -> Bool {
        guard let dictionary else { return true }
        guard dictionary.count <= maximumJSONCollectionCount else { return false }
        return dictionary.allSatisfy {
            $0.key.utf8.count <= maximumJSONStringBytes
                && jsonValueWithinBounds($0.value, depth: 1)
        }
    }

    private static func jsonValueWithinBounds(_ value: JSONValue, depth: Int) -> Bool {
        guard depth <= maximumJSONNestingDepth else { return false }
        switch value {
        case .null, .bool, .int, .double:
            return true
        case .string(let string):
            return string.utf8.count <= maximumJSONStringBytes
        case .array(let values):
            return values.count <= maximumJSONCollectionCount
                && values.allSatisfy { jsonValueWithinBounds($0, depth: depth + 1) }
        case .object(let pairs):
            return pairs.count <= maximumJSONCollectionCount
                && pairs.allSatisfy {
                    $0.0.utf8.count <= maximumJSONStringBytes
                        && jsonValueWithinBounds($0.1, depth: depth + 1)
                }
        }
    }

    static func validateManifestBounds(_ manifest: ModelManifest) throws {
        let strings = [
            manifest.modelID, manifest.version, manifest.r2Prefix,
            manifest.aggregateSHA256,
        ]
        guard manifest.files.count <= maximumManifestFileCount,
            strings.allSatisfy({ $0.utf8.count <= maximumJSONStringBytes }),
            manifest.files.allSatisfy({ file in
                file.path.utf8.count <= maximumJSONStringBytes
                    && file.sha256.utf8.count <= maximumJSONStringBytes
                    && file.role.utf8.count <= maximumJSONStringBytes
            })
        else {
            throw ModelCatalogError.decodeFailed("manifest exceeds provider structural bound")
        }
    }
}
