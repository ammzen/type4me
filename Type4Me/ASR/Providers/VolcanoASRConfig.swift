import Foundation

struct VolcanoASRConfig: ASRProviderConfig, Sendable {

    static let provider = ASRProvider.volcano
    static var displayName: String { L("火山引擎 (Doubao)", "Volcano (Doubao)") }

    /// 豆包流式语音识别模型 2.0
    static let resourceIdSeedASR = "volc.seedasr.sauc.duration"
    /// 豆包流式语音识别模型 1.0
    static let resourceIdBigASR = "volc.bigasr.sauc.duration"
    /// Auto: prefer 2.0, fall back to 1.0
    static let resourceIdAuto = "auto"

    /// Credential keys retired when Volcengine moved to single-API-Key auth.
    static let retiredCredentialKeys = ["appKey", "accessKey"]

    static var credentialFields: [CredentialField] {[
        CredentialField(key: "apiKey", label: "API Key", placeholder: L("粘贴 API Key", "Paste your API Key"), isSecure: true, isOptional: false, defaultValue: ""),
        CredentialField(
            key: "resourceId",
            label: L("识别模型", "Model"),
            placeholder: "",
            isSecure: false,
            isOptional: false,
            defaultValue: resourceIdAuto,
            options: [
                FieldOption(value: resourceIdAuto, label: L("自动（优先 2.0，额度用完切 1.0）", "Auto (prefer 2.0, fallback to 1.0)")),
                FieldOption(value: resourceIdSeedASR, label: L("流式语音识别模型 2.0", "Streaming ASR Model 2.0")),
                FieldOption(value: resourceIdBigASR, label: L("流式语音识别大模型", "Streaming ASR Large Model")),
            ]
        ),
    ]}

    let apiKey: String
    let resourceId: String
    let uid: String

    init?(credentials: [String: String]) {
        guard let apiKey = credentials["apiKey"], !apiKey.isEmpty else { return nil }
        self.apiKey = apiKey
        let raw = credentials["resourceId"] ?? Self.resourceIdAuto
        if raw == Self.resourceIdAuto || raw.isEmpty {
            // Use resolved value from auto-detect, or default to seed
            self.resourceId = credentials["resolvedResourceId"]?.isEmpty == false
                ? credentials["resolvedResourceId"]!
                : Self.resourceIdSeedASR
        } else {
            self.resourceId = raw
        }
        self.uid = ASRIdentityStore.loadOrCreateUID()
    }

    func toCredentials() -> [String: String] {
        ["apiKey": apiKey, "resourceId": resourceId]
    }

    var isValid: Bool {
        !apiKey.isEmpty
    }
}
