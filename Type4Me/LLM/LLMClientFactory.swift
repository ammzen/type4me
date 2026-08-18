import Foundation

enum LLMClientFactory {
    static func make(
        for provider: LLMProvider,
        bypassProxy: Bool = ProxyBypassMode.current.bypassLLM
    ) -> any LLMClient {
        switch provider {
        case .claude:
            return ClaudeChatClient(bypassProxy: bypassProxy)
        case .codexCLI:
            return CodexCLIClient()
        default:
            return DoubaoChatClient(provider: provider, bypassProxy: bypassProxy)
        }
    }
}
