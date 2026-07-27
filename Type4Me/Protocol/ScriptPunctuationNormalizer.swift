import Foundation

/// Normalizes punctuation style to match the transcript script / configured language.
enum ScriptPunctuationNormalizer {

    private static let cjkLanguageCodes: Set<String> = ["zh", "zh-tw", "ja", "ko"]

    private static let cjkToLatinMap: [Character: Character] = [
        "，": ",", "。": ".", "！": "!", "？": "?", "；": ";", "：": ":",
        "（": "(", "）": ")", "【": "[", "】": "]",
        "\u{201C}": "\"", "\u{201D}": "\"",
        "\u{2018}": "'", "\u{2019}": "'",
        "、": ",",
    ]

    /// Whether CJK punctuation in `text` should be converted to Latin punctuation.
    static func shouldUseLatinPunctuation(languageCode: String, text: String) -> Bool {
        let normalizedLanguage = languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cjkLanguageCodes.contains(normalizedLanguage) {
            return false
        }
        if !normalizedLanguage.isEmpty {
            return true
        }
        return !text.contains(where: \.isCJKUnifiedIdeograph)
    }

    static func normalizeCJKPunctuationToLatin(_ text: String) -> String {
        String(text.map { cjkToLatinMap[$0] ?? $0 })
    }

    static func normalizeIfNeeded(languageCode: String, text: String) -> String {
        guard shouldUseLatinPunctuation(languageCode: languageCode, text: text) else {
            return text
        }
        return normalizeCJKPunctuationToLatin(text)
    }
}
