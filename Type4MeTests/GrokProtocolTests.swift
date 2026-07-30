import XCTest
@testable import Type4Me

final class GrokProtocolTests: XCTestCase {

    func testBuildWebSocketURL_includesStreamingParams() throws {
        let config = try XCTUnwrap(GrokASRConfig(credentials: [
            "apiKey": "xai_test_key",
            "language": "en",
        ]))
        let url = try GrokProtocol.buildWebSocketURL(
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me"])
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.x.ai")
        XCTAssertEqual(components.path, "/v1/stt")
        XCTAssertEqual(items.value(for: "sample_rate"), "16000")
        XCTAssertEqual(items.value(for: "encoding"), "pcm")
        XCTAssertEqual(items.value(for: "interim_results"), "true")
        XCTAssertEqual(items.value(for: "language"), "en")
        XCTAssertEqual(items.values(for: "keyterm"), ["Type4Me"])
    }

    func testMakeTranscriptUpdate_marksServerReadyOnCreated() throws {
        let message = """
        {"type": "transcript.created"}
        """

        let update = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                confirmedSegments: []
            )
        )

        XCTAssertTrue(update.serverReady)
    }

    func testMakeTranscriptUpdate_parsesInterimPartial() throws {
        let message = """
        {"type": "transcript.partial", "text": "Hello world", "is_final": false, "speech_final": false}
        """

        let update = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                confirmedSegments: []
            )
        )

        XCTAssertEqual(update.transcript.partialText, "Hello world")
        XCTAssertFalse(update.transcript.isFinal)
    }

    func testMakeTranscriptUpdate_parsesFinalPartialOnCommit() throws {
        let message = """
        {"type": "transcript.partial", "text": "Hello world", "is_final": true, "speech_final": true}
        """

        let update = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                confirmedSegments: [],
                isFinalCommit: true
            )
        )

        XCTAssertEqual(update.confirmedSegments, ["Hello world"])
        XCTAssertTrue(update.transcript.isFinal)
    }

    func testFinalizeAndAudioDoneMessages() {
        XCTAssertEqual(GrokProtocol.finalizeMessage(), "{\"type\":\"finalize\"}")
        XCTAssertEqual(GrokProtocol.audioDoneMessage(), "{\"type\":\"audio.done\"}")
    }
}

private extension Array where Element == URLQueryItem {
    func value(for name: String) -> String? {
        first { $0.name == name }?.value
    }

    func values(for name: String) -> [String] {
        filter { $0.name == name }.compactMap(\.value)
    }
}
