import Foundation

extension CBv2RequestGeometry {
    init(loaded: LoadedModel, maximumTokens: Int) throws {
        try self.init(model: loaded.model, family: loaded.family, feedForwardKind: loaded.feedForwardKind,
            layerCount: loaded.layerCount, vocabularySize: loaded.vocabularySize,
            configurationData: loaded.configurationData, maximumTokens: maximumTokens)
    }
}
