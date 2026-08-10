import Foundation

struct ResolvedLLMRuntime: Sendable {
    let providerID: String
    let client: any LLMClient
    let config: LLMConfig
}

enum LLMRuntime {
    static func resolve(isCloudMode: Bool = false) -> ResolvedLLMRuntime? {
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode {
            return ResolvedLLMRuntime(
                providerID: "cloud",
                client: CloudLLMClient(),
                config: LLMConfig(apiKey: "", model: "cloud")
            )
        }
        #endif

        let provider = KeychainService.selectedLLMProvider
        guard let config = KeychainService.loadLLMProviderConfig(for: provider)?.toLLMConfig() else {
            return nil
        }
        return ResolvedLLMRuntime(
            providerID: provider.rawValue,
            client: LLMClientFactory.make(for: provider),
            config: config
        )
    }

    static func currentClient(isCloudMode: Bool = false) -> any LLMClient {
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode { return CloudLLMClient() }
        #endif

        return LLMClientFactory.make(for: KeychainService.selectedLLMProvider)
    }

    static func currentConfig(isCloudMode: Bool = false) -> LLMConfig? {
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode { return LLMConfig(apiKey: "", model: "cloud") }
        #endif

        return KeychainService.loadLLMConfig()
    }
}
