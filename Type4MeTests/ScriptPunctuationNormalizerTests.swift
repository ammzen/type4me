import XCTest
@testable import Type4Me

final class ScriptPunctuationNormalizerTests: XCTestCase {

    func testShouldUseLatinPunctuation_explicitEnglish() {
        XCTAssertTrue(
            ScriptPunctuationNormalizer.shouldUseLatinPunctuation(languageCode: "en", text: "你好")
        )
    }

    func testShouldUseLatinPunctuation_explicitChinese() {
        XCTAssertFalse(
            ScriptPunctuationNormalizer.shouldUseLatinPunctuation(languageCode: "zh", text: "Hello world")
        )
    }

    func testShouldUseLatinPunctuation_autoDetectLatinOnly() {
        XCTAssertTrue(
            ScriptPunctuationNormalizer.shouldUseLatinPunctuation(languageCode: "", text: "Hello world")
        )
    }

    func testShouldUseLatinPunctuation_autoDetectWithCJK() {
        XCTAssertFalse(
            ScriptPunctuationNormalizer.shouldUseLatinPunctuation(languageCode: "", text: "你好 world")
        )
    }

    func testNormalizeCJKPunctuationToLatin_convertsCommonMarks() {
        let input = "Hello world。How are you？Great！"
        XCTAssertEqual(
            ScriptPunctuationNormalizer.normalizeCJKPunctuationToLatin(input),
            "Hello world.How are you?Great!"
        )
    }

    func testNormalizeIfNeeded_keepsChineseWhenConfigured() {
        let input = "你好世界。"
        XCTAssertEqual(
            ScriptPunctuationNormalizer.normalizeIfNeeded(languageCode: "zh", text: input),
            input
        )
    }

    func testNormalizeIfNeeded_convertsForAutoDetectedEnglish() {
        XCTAssertEqual(
            ScriptPunctuationNormalizer.normalizeIfNeeded(languageCode: "", text: "Hello world。"),
            "Hello world."
        )
    }
}
