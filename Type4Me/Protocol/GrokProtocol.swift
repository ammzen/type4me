import Foundation

enum GrokProtocolError: Error, LocalizedError {
    case invalidEndpoint
    case serverError(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Failed to build Grok WebSocket URL"
        case .serverError(let message):
            return message.isEmpty ? "Grok STT error" : "Grok STT error: \(message)"
        }
    }
}

struct GrokTranscriptUpdate: Sendable, Equatable {
    let transcript: RecognitionTranscript
    let confirmedSegments: [String]
    let serverReady: Bool
}

enum GrokProtocol {

    private static let endpoint = "wss://api.x.ai/v1/stt"
    private static let sampleRate = 16000

    static func buildWebSocketURL(config: GrokASRConfig, options: ASRRequestOptions) throws -> URL {
        guard var components = URLComponents(string: endpoint) else {
            throw GrokProtocolError.invalidEndpoint
        }

        var queryItems = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "filler_words", value: "false"),
        ]

        if !config.language.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: config.language))
        }

        let keyterms = options.hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 50 }
            .prefix(100)
        for term in keyterms {
            queryItems.append(URLQueryItem(name: "keyterm", value: term))
        }

        components.queryItems = queryItems
        guard let url = components.url else {
            throw GrokProtocolError.invalidEndpoint
        }
        return url
    }

    static func finalizeMessage() -> String {
        jsonString(["type": "finalize"])
    }

    static func audioDoneMessage() -> String {
        jsonString(["type": "audio.done"])
    }

    private struct InboundMessage: Decodable {
        let type: String
        let text: String?
        let isFinal: Bool?
        let speechFinal: Bool?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case type, text, message
            case isFinal = "is_final"
            case speechFinal = "speech_final"
        }
    }

    static func makeTranscriptUpdate(
        from data: Data,
        confirmedSegments: [String],
        isFinalCommit: Bool = false
    ) throws -> GrokTranscriptUpdate? {
        guard data.first == UInt8(ascii: "{") else { return nil }
        let message = try JSONDecoder().decode(InboundMessage.self, from: data)

        switch message.type {
        case "transcript.created":
            return GrokTranscriptUpdate(
                transcript: .empty,
                confirmedSegments: confirmedSegments,
                serverReady: true
            )

        case "transcript.partial":
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }

            let isFinal = message.isFinal ?? false
            let speechFinal = message.speechFinal ?? false

            if !isFinal {
                let confirmed = confirmedSegments.joined()
                let partialOnly = stripConfirmedPrefix(from: text, confirmed: confirmed)
                guard !partialOnly.isEmpty else { return nil }
                let normalized = normalize(segment: partialOnly, after: confirmed)
                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: normalized,
                    authoritativeText: (confirmedSegments + [normalized]).joined(),
                    isFinal: false
                )
                return GrokTranscriptUpdate(
                    transcript: transcript,
                    confirmedSegments: confirmedSegments,
                    serverReady: false
                )
            }

            if speechFinal {
                let next = finalizeSpeechFinal(text, confirmedSegments: confirmedSegments)
                let transcript = RecognitionTranscript(
                    confirmedSegments: next,
                    partialText: "",
                    authoritativeText: next.joined(),
                    isFinal: isFinalCommit
                )
                return GrokTranscriptUpdate(
                    transcript: transcript,
                    confirmedSegments: next,
                    serverReady: false
                )
            }

            let next = appendChunk(text, to: confirmedSegments)
            let transcript = RecognitionTranscript(
                confirmedSegments: next,
                partialText: "",
                authoritativeText: next.joined(),
                isFinal: false
            )
            return GrokTranscriptUpdate(
                transcript: transcript,
                confirmedSegments: next,
                serverReady: false
            )

        case "transcript.done":
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                let joined = confirmedSegments.joined()
                guard !joined.isEmpty else { return nil }
                let transcript = RecognitionTranscript(
                    confirmedSegments: confirmedSegments,
                    partialText: "",
                    authoritativeText: joined,
                    isFinal: isFinalCommit
                )
                return GrokTranscriptUpdate(
                    transcript: transcript,
                    confirmedSegments: confirmedSegments,
                    serverReady: false
                )
            }

            let next = finalizeSessionDone(text, confirmedSegments: confirmedSegments)
            let transcript = RecognitionTranscript(
                confirmedSegments: next,
                partialText: "",
                authoritativeText: next.joined(),
                isFinal: isFinalCommit
            )
            return GrokTranscriptUpdate(
                transcript: transcript,
                confirmedSegments: next,
                serverReady: false
            )

        case "error":
            throw GrokProtocolError.serverError(message: message.message ?? "")

        default:
            return nil
        }
    }

    private static func jsonString(_ payload: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func appendChunk(_ chunk: String, to segments: [String]) -> [String] {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return segments }
        let joined = segments.joined()
        if joined.isEmpty { return [trimmed] }
        if joined == trimmed || joined.hasSuffix(trimmed) { return segments }
        return segments + [normalize(segment: trimmed, after: joined)]
    }

    /// xAI `speech_final` ends one utterance, not the whole session. Append new sentences;
    /// collapse trailing chunk finals when the utterance stitches them.
    private static func finalizeSpeechFinal(_ text: String, confirmedSegments: [String]) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return confirmedSegments }
        guard !confirmedSegments.isEmpty else { return [trimmed] }

        let joined = confirmedSegments.joined()
        let joinedTrimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)

        if joinedTrimmed == trimmed || joined.hasSuffix(trimmed) { return confirmedSegments }

        // Cumulative stitch for the current utterance (includes prior confirmed text).
        if trimmed.hasPrefix(joinedTrimmed) {
            return [trimmed]
        }

        // Refinement of trailing chunk finals within the same utterance.
        if let last = confirmedSegments.last {
            let lastTrimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
            if !lastTrimmed.isEmpty && trimmed.localizedCaseInsensitiveContains(lastTrimmed) {
                var prefix = confirmedSegments.dropLast()
                while let tail = prefix.last,
                      trimmed.localizedCaseInsensitiveContains(tail.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    prefix = prefix.dropLast()
                }
                let prior = Array(prefix)
                if prior.isEmpty { return [trimmed] }
                return prior + [normalize(segment: trimmed, after: prior.joined())]
            }
        }

        // Distinct new utterance in the same session.
        return confirmedSegments + [normalize(segment: trimmed, after: joined)]
    }

    /// `transcript.done` is authoritative for the full session when it supersedes confirmed text.
    private static func finalizeSessionDone(_ text: String, confirmedSegments: [String]) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return confirmedSegments }

        let joined = confirmedSegments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty { return [trimmed] }
        if trimmed == joined || trimmed.hasPrefix(joined) || trimmed.count >= joined.count {
            return [trimmed]
        }
        return confirmedSegments + [normalize(segment: trimmed, after: confirmedSegments.joined())]
    }

    private static func stripConfirmedPrefix(from text: String, confirmed: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty else { return trimmed }
        let prefix = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func normalize(segment: String, after existingText: String) -> String {
        guard !segment.isEmpty, let last = existingText.last, let first = segment.first else {
            return segment
        }
        if last.isWhitespace || first.isWhitespace { return segment }
        if first.isClosingPunctuation || last.isOpeningPunctuation { return segment }
        if last.isCJKUnifiedIdeograph || first.isCJKUnifiedIdeograph { return segment }
        return " " + segment
    }
}
