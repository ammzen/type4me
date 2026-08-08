import XCTest
@testable import Type4Me

final class CorrectionDiffAnalyzerTests: XCTestCase {
    func testEnglishWordCorrection() throws {
        let baseline = "Please use ghosty today"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: try range(of: "ghosty", in: baseline),
            current: "Please use Ghostty today"
        )
        XCTAssertEqual(result, .candidate(wrongText: "ghosty", correctedText: "Ghostty"))
    }

    func testSpaceCorrectionExpandsToWords() throws {
        let baseline = "Use Open AI here"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: try range(of: "Open AI", in: baseline),
            current: "Use OpenAI here"
        )
        XCTAssertEqual(result, .candidate(wrongText: "Open AI", correctedText: "OpenAI"))
    }

    func testInsertedBrandPunctuationExpandsToWord() throws {
        let baseline = "Try Nextjs now"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: try range(of: "Nextjs", in: baseline),
            current: "Try Next.js now"
        )
        XCTAssertEqual(result, .candidate(wrongText: "Nextjs", correctedText: "Next.js"))
    }

    func testSingleChineseCharacterCorrectionIsRejectedAsAmbiguous() throws {
        let baseline = "我们使用阶越星辰模型"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: NSRange(baseline.startIndex..<baseline.endIndex, in: baseline),
            current: "我们使用阶跃星辰模型"
        )
        XCTAssertEqual(result, .rejected(.ambiguousCJKReplacement))
    }

    func testMultiCharacterChineseReplacementKeepsExactDiff() throws {
        let baseline = "这个问题和一个人的加好程度其实是有关系的"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: NSRange(baseline.startIndex..<baseline.endIndex, in: baseline),
            current: "这个问题和一个人的佳豪程度其实是有关系的"
        )
        XCTAssertEqual(result, .candidate(wrongText: "加好", correctedText: "佳豪"))
    }

    func testUnrelatedTypingOutsideInjectionDoesNotHideCorrection() throws {
        let baseline = "prefix ghosty suffix"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: try range(of: "ghosty", in: baseline),
            current: "new prefix Ghostty suffix tail"
        )
        XCTAssertEqual(result, .candidate(wrongText: "ghosty", correctedText: "Ghostty"))
    }

    func testMultipleCorrectionsInsideInjectionAreRejected() {
        let baseline = "ghosty and Nextjs"
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: baseline,
            injectedRange: NSRange(baseline.startIndex..<baseline.endIndex, in: baseline),
            current: "Ghostty and Next.js"
        )
        XCTAssertEqual(result, .rejected(.multipleChanges))
    }

    func testPureWordInsertionAndDeletionAreRejected() {
        let insertion = CorrectionDiffAnalyzer.analyze(
            baseline: "Open model",
            injectedRange: NSRange(location: 0, length: 10),
            current: "Open AI model"
        )
        if case .candidate = insertion { XCTFail("Pure insertion must not become a candidate") }

        let deletion = CorrectionDiffAnalyzer.analyze(
            baseline: "Open AI model",
            injectedRange: NSRange(location: 0, length: 13),
            current: "Open model"
        )
        if case .candidate = deletion { XCTFail("Pure deletion must not become a candidate") }
    }

    func testPurePunctuationReplacementIsRejected() {
        let result = CorrectionDiffAnalyzer.analyze(
            baseline: "hello.",
            injectedRange: NSRange(location: 0, length: 6),
            current: "hello!"
        )
        XCTAssertEqual(result, .rejected(.invalidCandidate))
    }

    func testSensitiveAndOverlongCandidatesAreRejected() {
        let emailBaseline = "wrong@example.com"
        let emailResult = CorrectionDiffAnalyzer.analyze(
            baseline: emailBaseline,
            injectedRange: NSRange(emailBaseline.startIndex..<emailBaseline.endIndex, in: emailBaseline),
            current: "right@example.com"
        )
        XCTAssertEqual(emailResult, .rejected(.sensitiveContent))

        let longWrong = String(repeating: "a", count: 33)
        let longCorrect = String(repeating: "a", count: 32) + "b"
        let longResult = CorrectionDiffAnalyzer.analyze(
            baseline: longWrong,
            injectedRange: NSRange(longWrong.startIndex..<longWrong.endIndex, in: longWrong),
            current: longCorrect
        )
        XCTAssertEqual(longResult, .rejected(.invalidCandidate))
    }

    private func range(of substring: String, in text: String) throws -> NSRange {
        guard let range = text.range(of: substring) else {
            throw NSError(domain: "CorrectionDiffAnalyzerTests", code: 1)
        }
        return NSRange(range, in: text)
    }
}

final class CorrectionLearningStoreTests: XCTestCase {
    func testLearnsHotwordAndMappingTogether() throws {
        let persistence = FakeCorrectionPersistence()
        let store = CorrectionLearningStore(persistence: persistence)
        try store.learn(candidate(wrong: "ghosty", corrected: "Ghostty"))

        XCTAssertEqual(persistence.hotwords, ["Ghostty"])
        XCTAssertEqual(
            persistence.mappings,
            [CorrectionMapping(trigger: "ghosty", replacement: "Ghostty")]
        )
    }

    func testDeduplicatesHotwordAndUpdatesConflictingMapping() throws {
        let persistence = FakeCorrectionPersistence(
            hotwords: ["GHOSTTY"],
            mappings: [CorrectionMapping(trigger: "Ghosty", replacement: "Old")]
        )
        let store = CorrectionLearningStore(persistence: persistence)
        try store.learn(candidate(wrong: "ghosty", corrected: "Ghostty"))

        XCTAssertEqual(persistence.hotwords, ["GHOSTTY"])
        XCTAssertEqual(
            persistence.mappings,
            [CorrectionMapping(trigger: "ghosty", replacement: "Ghostty")]
        )
        XCTAssertEqual(persistence.hotwordSaveCount, 0)
        XCTAssertEqual(persistence.mappingSaveCount, 1)
    }

    func testMappingFailureRollsBackHotwords() {
        let persistence = FakeCorrectionPersistence()
        persistence.failMappingSave = true
        let store = CorrectionLearningStore(persistence: persistence)

        XCTAssertThrowsError(try store.learn(candidate(wrong: "ghosty", corrected: "Ghostty")))
        XCTAssertEqual(persistence.hotwords, [])
        XCTAssertEqual(persistence.mappings, [])
    }

    private func candidate(wrong: String, corrected: String) -> CorrectionCandidate {
        CorrectionCandidate(
            wrongText: wrong,
            correctedText: corrected,
            sourceRecordID: "record",
            bundleIdentifier: "com.example.editor"
        )
    }
}

final class CorrectionLearningEligibilityTests: XCTestCase {
    @MainActor
    func testOnlyQuickModeAndVoicePolishAreSupported() {
        XCTAssertTrue(CorrectionLearningCoordinator.supports(modeID: ProcessingMode.directId))
        XCTAssertTrue(CorrectionLearningCoordinator.supports(modeID: ProcessingMode.formalWritingId))
        XCTAssertFalse(CorrectionLearningCoordinator.supports(modeID: ProcessingMode.translateId))
        XCTAssertFalse(CorrectionLearningCoordinator.supports(modeID: UUID()))
    }

    func testPrivacyWindowAndChineseInputDebounceMatchV1Settings() {
        XCTAssertEqual(CorrectionLearningCoordinator.observationDuration, .seconds(60))
        XCTAssertEqual(CorrectionLearningCoordinator.debounceDuration, .seconds(4))
    }
}

private final class FakeCorrectionPersistence: CorrectionVocabularyPersisting {
    var hotwords: [String]
    var mappings: [CorrectionMapping]
    var failMappingSave = false
    var hotwordSaveCount = 0
    var mappingSaveCount = 0

    init(hotwords: [String] = [], mappings: [CorrectionMapping] = []) {
        self.hotwords = hotwords
        self.mappings = mappings
    }

    func loadHotwords() -> [String] { hotwords }
    func loadMappings() -> [CorrectionMapping] { mappings }

    func saveHotwords(_ words: [String]) throws {
        hotwordSaveCount += 1
        hotwords = words
    }

    func saveMappings(_ mappings: [CorrectionMapping]) throws {
        mappingSaveCount += 1
        if failMappingSave { throw NSError(domain: "FakeCorrectionPersistence", code: 1) }
        self.mappings = mappings
    }
}
