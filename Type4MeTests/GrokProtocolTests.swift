import XCTest
@testable import Type4Me

final class GrokProtocolTests: XCTestCase {

    private func state(utterances: [String] = [], chunks: [String] = []) -> GrokTranscriptState {
        GrokTranscriptState(utterances: utterances, currentChunks: chunks)
    }

    func testBuildWebSocketURL_includesStreamingParams() throws {
        let config = try XCTUnwrap(GrokASRConfig(credentials: [
            "apiKey": "xai_test_key",
            "language": "en",
        ]))
        let url = try GrokProtocol.buildWebSocketURL(
            config: config,
            options: ASRRequestOptions(hotwords: ["Type4Me", "Understand The Universe"])
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = components.queryItems ?? []

        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "api.x.ai")
        XCTAssertEqual(components.path, "/v1/stt")
        XCTAssertEqual(items.value(for: "sample_rate"), "16000")
        XCTAssertEqual(items.value(for: "encoding"), "pcm")
        XCTAssertEqual(items.value(for: "interim_results"), "true")
        XCTAssertEqual(items.value(for: "filler_words"), "false")
        XCTAssertEqual(items.value(for: "language"), "en")
        XCTAssertEqual(items.values(for: "keyterm"), ["Type4Me", "Understand The Universe"])
    }

    func testMakeTranscriptUpdate_marksServerReadyOnCreated() throws {
        let message = """
        {"type": "transcript.created"}
        """

        let update = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                state: .empty
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
                state: .empty
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
                state: state(utterances: ["Hello"]),
                isFinalCommit: true
            )
        )

        XCTAssertEqual(update.confirmedSegments, ["Hello world"])
        XCTAssertEqual(update.transcript.authoritativeText, "Hello world")
        XCTAssertTrue(update.transcript.isFinal)
    }

    func testMakeTranscriptUpdate_appendsChunkFinalsWithoutDuplicating() throws {
        let chunk1 = """
        {"type": "transcript.partial", "text": "To add some", "is_final": true, "speech_final": false}
        """
        let first = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(chunk1.utf8),
                state: .empty
            )
        )
        XCTAssertEqual(first.state.currentChunks, ["To add some"])

        let duplicateChunk = """
        {"type": "transcript.partial", "text": "To add some", "is_final": true, "speech_final": false}
        """
        let second = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(duplicateChunk.utf8),
                state: first.state
            )
        )
        XCTAssertEqual(second.state.currentChunks, ["To add some"])

        let chunk2 = """
        {"type": "transcript.partial", "text": "For future training", "is_final": true, "speech_final": false}
        """
        let third = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(chunk2.utf8),
                state: second.state
            )
        )
        XCTAssertEqual(third.confirmedSegments, ["To add some", " For future training"])
    }

    func testMakeTranscriptUpdate_speechFinalReplacesChunkSegments() throws {
        let speechFinal = """
        {"type": "transcript.partial", "text": "To add some for future training.", "is_final": true, "speech_final": true}
        """
        let update = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(speechFinal.utf8),
                state: state(chunks: ["To add some", " For future training"]),
                isFinalCommit: true
            )
        )

        XCTAssertEqual(update.confirmedSegments, ["To add some for future training."])
        XCTAssertTrue(update.transcript.isFinal)
    }

    func testMakeTranscriptUpdate_speechFinalAppendsMultipleSentences() throws {
        let sentenceOne = """
        {"type": "transcript.partial", "text": "This is sentence one.", "is_final": true, "speech_final": true}
        """
        let first = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(sentenceOne.utf8),
                state: .empty
            )
        )
        XCTAssertEqual(first.state.utterances, ["This is sentence one."])

        let sentenceTwo = """
        {"type": "transcript.partial", "text": "This is sentence two.", "is_final": true, "speech_final": true}
        """
        let second = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(sentenceTwo.utf8),
                state: first.state
            )
        )

        XCTAssertEqual(
            second.state.utterances,
            ["This is sentence one.", " This is sentence two."]
        )
        XCTAssertEqual(
            second.transcript.authoritativeText,
            "This is sentence one. This is sentence two."
        )
    }

    func testMakeTranscriptUpdate_speechFinalSkipsNearDuplicateUtterance() throws {
        let sentenceOne = """
        {"type": "transcript.partial", "text": "Thank you for the update and the follow-up.", "is_final": true, "speech_final": true}
        """
        let first = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(sentenceOne.utf8),
                state: .empty
            )
        )

        let sentenceTwo = """
        {"type": "transcript.partial", "text": "Thank you for the update and the follow up.", "is_final": true, "speech_final": true}
        """
        let second = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(sentenceTwo.utf8),
                state: first.state
            )
        )

        XCTAssertEqual(second.state.utterances, first.state.utterances)
        XCTAssertEqual(second.transcript.authoritativeText, "Thank you for the update and the follow-up.")
    }

    func testMakeTranscriptUpdate_speechFinalRevisesShortUtterance() throws {
        let short = """
        {"type": "transcript.partial", "text": "Sure.", "is_final": true, "speech_final": true}
        """
        let first = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(short.utf8),
                state: .empty
            )
        )

        let longer = """
        {"type": "transcript.partial", "text": "Sure, we can start from two weeks.", "is_final": true, "speech_final": true}
        """
        let second = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(longer.utf8),
                state: first.state
            )
        )

        XCTAssertEqual(second.state.utterances, ["Sure, we can start from two weeks."])
        XCTAssertEqual(second.transcript.authoritativeText, "Sure, we can start from two weeks.")
    }

    func testMakeTranscriptUpdate_transcriptDoneDedupesRepeatedTail() throws {
        let message = """
        {"type": "transcript.done", "text": "Thank you for the update and the follow-up. Thank you for the update and the follow up.", "duration": 3.2}
        """
        let update = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                state: state(utterances: ["Thank you for the update and the follow-up."]),
                isFinalCommit: true
            )
        )

        XCTAssertEqual(update.confirmedSegments, ["Thank you for the update and the follow-up."])
        XCTAssertEqual(update.transcript.authoritativeText, "Thank you for the update and the follow-up.")
    }

    func testMakeTranscriptUpdate_transcriptDoneReplacesConfirmedSegments() throws {
        let message = """
        {"type": "transcript.done", "text": "Hello world", "duration": 1.2}
        """
        let update = try XCTUnwrap(
            GrokProtocol.makeTranscriptUpdate(
                from: Data(message.utf8),
                state: state(chunks: ["Hello", " world"]),
                isFinalCommit: true
            )
        )

        XCTAssertEqual(update.confirmedSegments, ["Hello world"])
        XCTAssertEqual(update.transcript.authoritativeText, "Hello world")
        XCTAssertTrue(update.transcript.isFinal)
    }

    func testDedupeOverlappingPhrases_collapsesRepeatedOnboardingClauses() {
        let noisy = """
        Getting started and we pick up some of the projects in the human-in-loop Getting started and we pick up some of the projects in the half Per care phase two for them to get an understanding of what we are Per care phase two for them to get an understanding what we are busy or struggle with.
        """
        let deduped = GrokProtocol.dedupeOverlappingPhrases(noisy)
        XCTAssertFalse(deduped.contains("Getting started and we pick up some of the projects in the human-in-loop Getting started"))
        XCTAssertEqual(
            deduped,
            "Getting started and we pick up some of the projects in the half Per care phase two for them to get an understanding what we are busy or struggle with."
        )
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
