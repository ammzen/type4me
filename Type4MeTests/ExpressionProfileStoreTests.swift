import XCTest
@testable import Type4Me
@testable import Type4MeIntelliSenseCore

final class ExpressionProfileStoreTests: XCTestCase {
    func testExtractorStoresOnlyAbstractFeatures() throws {
        let observation = ExpressionObservation(
            sessionID: "session-secret",
            createdAt: Date(),
            appBundleIdentifier: "com.example.Editor",
            appCategory: .document,
            injectedText: "这是第一句话这是第二句话内容比较长",
            finalObservedText: "这是第一句话。\n这是第二句话，内容比较长。",
            correctionCandidateRange: nil
        )
        let sample = try XCTUnwrap(ExpressionFeatureExtractor.extract(observation))
        XCTAssertTrue(sample.wasEdited)
        XCTAssertEqual(Set(sample.values.keys), Set(ExpressionFeature.allCases))
    }

    func testStableAppProfileOverridesCategoryAndGlobal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileURL = directory.appendingPathComponent("profile.json")
        let store = ExpressionProfileStore(
            fileURL: profileURL,
            thresholds: ExpressionLearningThresholds(
                learningSamples: 2,
                stableSamples: 3,
                stableDaySpan: 2,
                directionalConsistency: 0.6,
                editedWeight: 1,
                acceptedWeight: 0.25
            )
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for day in 0..<3 {
            try await store.record(ExpressionObservation(
                sessionID: "s\(day)",
                createdAt: Calendar.current.date(byAdding: .day, value: day, to: start)!,
                appBundleIdentifier: "COM.EXAMPLE.EDITOR",
                appCategory: .document,
                injectedText: "这是第一句话这是第二句话内容比较长",
                finalObservedText: "这是第一句话。\n这是第二句话，内容比较长。",
                correctionCandidateRange: nil
            ))
        }

        let document = await store.documentForTesting()
        XCTAssertEqual(document.applications["com.example.editor"]?.sampleCount, 3)
        let persisted = String(decoding: try Data(contentsOf: profileURL), as: UTF8.self)
        XCTAssertFalse(persisted.contains("这是第一句话"))
        let effective = await store.effectiveProfile(
            bundleIdentifier: "com.example.editor",
            category: .document
        )
        XCTAssertNotNil(effective)
        let categoryFallback = await store.effectiveProfile(
            bundleIdentifier: "com.example.other-editor",
            category: .document
        )
        XCTAssertNotNil(categoryFallback)
        let globalFallback = await store.effectiveProfile(
            bundleIdentifier: "com.example.chat",
            category: .messaging
        )
        XCTAssertNotNil(globalFallback)

        let reloadedStore = ExpressionProfileStore(
            fileURL: profileURL,
            thresholds: ExpressionLearningThresholds(
                learningSamples: 2,
                stableSamples: 3,
                stableDaySpan: 2,
                directionalConsistency: 0.6,
                editedWeight: 1,
                acceptedWeight: 0.25
            )
        )
        let reloaded = await reloadedStore.documentForTesting()
        XCTAssertEqual(reloaded.applications["com.example.editor"]?.sampleCount, 3)

        try await store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileURL.path))
        let cleared = await store.effectiveProfile(
            bundleIdentifier: "com.example.editor",
            category: .document
        )
        XCTAssertNil(cleared)
    }

    func testRejectsSensitiveOrFactChangingEdits() {
        let sensitive = ExpressionObservation(
            sessionID: "s",
            createdAt: Date(),
            appBundleIdentifier: nil,
            appCategory: .other,
            injectedText: "请保存 api_key = abcdefghijklmnop",
            finalObservedText: "请妥善保存 api_key = abcdefghijklmnop",
            correctionCandidateRange: nil
        )
        XCTAssertNil(ExpressionFeatureExtractor.extract(sensitive))
    }
}
