// The Components' RemoteProviderDraft -> Remote's RemoteProviderConfig glue, straight from
// examples/model-switch/Sources/ModelSwitch/ProviderGlue.swift (docs/sdk-guide.md §6b calls this
// "the ~30 lines of glue a host writes").

import Foundation
import LocalLMLabSDKCore
import LocalLMLabSDKComponents
import LocalLMLabSDKRemote

extension RemoteProviderDraft {
    func makeConfig() -> RemoteProviderConfig? {
        let models = self.models.map { RemoteModel(id: $0) }
        var config: RemoteProviderConfig

        switch kind {
        case .openAIChat:
            guard !apiKey.isEmpty else { return nil }
            config = .openAI(apiKey: apiKey, models: models)
        case .openAIResponses:
            guard !apiKey.isEmpty else { return nil }
            config = .openAIResponses(apiKey: apiKey, models: models)
        case .anthropic:
            guard !apiKey.isEmpty else { return nil }
            config = .anthropic(apiKey: apiKey, models: models)
        case .openRouter:
            guard !apiKey.isEmpty else { return nil }
            config = .openRouter(apiKey: apiKey, models: models)
        case .openAICompatible:
            guard let url = URL(string: baseURL), !baseURL.isEmpty else { return nil }
            config = .openAICompatible(
                scheme: scheme, displayName: displayName, baseURL: url,
                apiKey: apiKey.isEmpty ? nil : apiKey, models: models)
        }

        // WebSearch intentionally NOT carried into defaultOptions here — this app always
        // searches through tavily_search (see AppModel.swift), not a provider's own native
        // web search, so every model (on-device or hosted) returns results from the same
        // source with the same schema.
        return config
    }
}
