import XCTest
import CryptoKit
@testable import Type4Me

final class ChineseWordSegmenterTests: XCTestCase {
    func testNativeSegmenterProducesRangesInsideOriginalString() async {
        let text = "我们使用智能感知模式"
        let spans = await NaturalLanguageChineseWordSegmenter().tokenSpans(in: text)

        XCTAssertFalse(spans.isEmpty)
        XCTAssertTrue(spans.allSatisfy { span in
            span.range.lowerBound >= text.startIndex && span.range.upperBound <= text.endIndex
        })
    }

    func testSingleHanReplacementRequiresJiebaAndNativeBoundaryAgreement() async {
        let segmenter = AgreeingChineseSegmenter()
        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "我们使用阶越星辰模型",
            edited: "我们使用阶跃星辰模型",
            chineseSegmenter: segmenter
        )

        XCTAssertEqual(
            result,
            .candidate(wrongText: "阶越星辰", correctedText: "阶跃星辰")
        )
    }

    func testNativeBoundaryAloneDoesNotPromoteSingleHanMapping() async {
        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "我们使用阶越星辰模型",
            edited: "我们使用阶跃星辰模型",
            chineseSegmenter: NativeOnlyChineseSegmenter()
        )

        XCTAssertEqual(result, .rejected(.ambiguousCJKReplacement))
    }

#if HAS_CPPJIEBA
    func testOnlyPinnedCompactResourcesAreBundledInRepository() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Type4Me/Resources/Jieba")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: resources.appendingPathComponent("jieba.dict.utf8").path
        ))
        XCTAssertEqual(
            sha256(try Data(contentsOf: resources.appendingPathComponent("dict.txt.small"))),
            "479cf8cc37e78bc908ae330d9153375547d4ff7f7d03a1ac4d4908d3677ff664"
        )
        XCTAssertEqual(
            sha256(try Data(contentsOf: resources.appendingPathComponent("hmm_model.utf8"))),
            "f17790586ac86dd048c8adffed052c4bd2b28ed0682972c1275e59040c0589a7"
        )
        let resourceBytes = try FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: [.fileSizeKey]
        ).reduce(0) { total, url in
            total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(resourceBytes, 2_621_440)

        let licenses = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CppJiebaBridge")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: licenses.appendingPathComponent("CPPJIEBA_LICENSE").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: licenses.appendingPathComponent("JIEBA_LICENSE").path
        ))
    }

    func testCompactJiebaLoadsAndReturnsUTF8SafeRanges() async throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Type4Me/Resources/Jieba")
        let overlay = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-jieba-\(UUID().uuidString).utf8")
        defer { try? FileManager.default.removeItem(at: overlay) }
        let segmenter = JiebaChineseWordSegmenter(
            resourceDirectory: resources,
            overlayURL: overlay
        )
        let text = "🙂中华人民共和国"

        let spans = await segmenter.tokenSpans(in: text)

        XCTAssertTrue(spans.contains { span in
            String(text[span.range]) == "中华人民共和国"
                && span.source == .jiebaAccurate
        })
    }

    func testRealCompactJiebaAndNativeTokenizerAgreeOnMixedScriptName() async throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Type4Me/Resources/Jieba")
        let overlay = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-jieba-mixed-\(UUID().uuidString).utf8")
        defer { try? FileManager.default.removeItem(at: overlay) }
        let segmenter = ExplicitHybridChineseSegmenter(
            jieba: JiebaChineseWordSegmenter(
                resourceDirectory: resources,
                overlayURL: overlay
            )
        )

        let result = await ImmediateCorrectionAnalyzer.analyze(
            original: "明天早上还要跟杰瑞开会",
            edited: "明天早上还要跟Jerry开会",
            chineseSegmenter: segmenter
        )

        XCTAssertEqual(result, .candidate(wrongText: "杰瑞", correctedText: "Jerry"))
    }

    func testConfirmedUserWordIsInsertedAndPersistedToOverlay() async throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Type4Me/Resources/Jieba")
        let overlay = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-jieba-\(UUID().uuidString).utf8")
        defer { try? FileManager.default.removeItem(at: overlay) }
        let segmenter = JiebaChineseWordSegmenter(
            resourceDirectory: resources,
            overlayURL: overlay
        )

        await segmenter.insertConfirmedUserWord("阶跃星辰")
        let text = "使用阶跃星辰模型"
        let spans = await segmenter.tokenSpans(in: text)

        XCTAssertTrue(spans.contains { String(text[$0.range]) == "阶跃星辰" })
        let persisted = try String(contentsOf: overlay, encoding: .utf8)
        XCTAssertTrue(persisted.contains("阶跃星辰"))
    }

    func testIdleJiebaUnloadsAndReloadsWithoutDuplicatingOverlay() async throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Type4Me/Resources/Jieba")
        let overlay = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-jieba-idle-\(UUID().uuidString).utf8")
        defer { try? FileManager.default.removeItem(at: overlay) }
        let segmenter = JiebaChineseWordSegmenter(
            resourceDirectory: resources,
            overlayURL: overlay,
            idleTimeout: .milliseconds(30)
        )

        await segmenter.insertConfirmedUserWord("阶跃星辰")
        let loadedAfterInsert = await segmenter.isLoadedForTesting()
        XCTAssertTrue(loadedAfterInsert)
        try await Task.sleep(for: .milliseconds(100))
        let loadedAfterIdle = await segmenter.isLoadedForTesting()
        XCTAssertFalse(loadedAfterIdle)

        let text = "使用阶跃星辰模型"
        let spans = await segmenter.tokenSpans(in: text)
        XCTAssertTrue(spans.contains { String(text[$0.range]) == "阶跃星辰" })
        let loadedAfterReload = await segmenter.isLoadedForTesting()
        XCTAssertTrue(loadedAfterReload)
        let lines = try String(contentsOf: overlay, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("阶跃星辰 ") }
        XCTAssertEqual(lines.count, 1)
    }

    func testMissingJiebaResourcesFallsBackWithoutLoading() async {
        let missingResources = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-jieba-\(UUID().uuidString)")
        let overlay = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-jieba-missing-\(UUID().uuidString).utf8")
        defer { try? FileManager.default.removeItem(at: overlay) }
        let segmenter = JiebaChineseWordSegmenter(
            resourceDirectory: missingResources,
            overlayURL: overlay
        )

        let spans = await segmenter.tokenSpans(in: "中文分词")

        XCTAssertTrue(spans.isEmpty)
        let loaded = await segmenter.isLoadedForTesting()
        XCTAssertFalse(loaded)
    }

    func testRuntimeSwitchReleasesLoadedJiebaOnNextCall() async throws {
        let defaults = UserDefaults.standard
        let key = JiebaChineseWordSegmenter.experimentDefaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(true, forKey: key)
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Type4Me/Resources/Jieba")
        let overlay = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-jieba-disabled-\(UUID().uuidString).utf8")
        defer { try? FileManager.default.removeItem(at: overlay) }
        let segmenter = JiebaChineseWordSegmenter(
            resourceDirectory: resources,
            overlayURL: overlay
        )

        _ = await segmenter.tokenSpans(in: "中文分词")
        let loadedBeforeDisable = await segmenter.isLoadedForTesting()
        XCTAssertTrue(loadedBeforeDisable)

        defaults.set(false, forKey: key)
        let disabledSpans = await segmenter.tokenSpans(in: "中文分词")
        let loadedAfterDisable = await segmenter.isLoadedForTesting()

        XCTAssertTrue(disabledSpans.isEmpty)
        XCTAssertFalse(loadedAfterDisable)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
#endif
}

#if HAS_CPPJIEBA
private actor ExplicitHybridChineseSegmenter: ChineseWordSegmenting {
    let jieba: JiebaChineseWordSegmenter
    let native = NaturalLanguageChineseWordSegmenter()

    init(jieba: JiebaChineseWordSegmenter) {
        self.jieba = jieba
    }

    func tokenSpans(in text: String) async -> [ChineseTokenSpan] {
        let jiebaSpans = await jieba.tokenSpans(in: text)
        let nativeSpans = await native.tokenSpans(in: text)
        return jiebaSpans + nativeSpans
    }
}
#endif

private struct AgreeingChineseSegmenter: ChineseWordSegmenting {
    func tokenSpans(in text: String) async -> [ChineseTokenSpan] {
        guard let range = text.range(of: text.contains("阶越") ? "阶越星辰" : "阶跃星辰") else {
            return []
        }
        return [
            ChineseTokenSpan(range: range, source: .jiebaAccurate),
            ChineseTokenSpan(range: range, source: .naturalLanguage),
        ]
    }
}

private struct NativeOnlyChineseSegmenter: ChineseWordSegmenting {
    func tokenSpans(in text: String) async -> [ChineseTokenSpan] {
        guard let range = text.range(of: text.contains("阶越") ? "阶越星辰" : "阶跃星辰") else {
            return []
        }
        return [ChineseTokenSpan(range: range, source: .naturalLanguage)]
    }
}
