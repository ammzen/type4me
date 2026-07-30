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

/// Separates committed utterances from in-flight chunk finals within the current pause.
struct GrokTranscriptState: Sendable, Equatable {
    var utterances: [String]
    var currentChunks: [String]

    static let empty = GrokTranscriptState(utterances: [], currentChunks: [])

    var confirmedSegments: [String] {
        GrokProtocol.flattenSegments(utterances: utterances, currentChunks: currentChunks)
    }

    var joinedConfirmed: String {
        confirmedSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct GrokTranscriptUpdate: Sendable, Equatable {
    let transcript: RecognitionTranscript
    let state: GrokTranscriptState
    let serverReady: Bool

    var confirmedSegments: [String] { state.confirmedSegments }
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
        state: GrokTranscriptState,
        isFinalCommit: Bool = false
    ) throws -> GrokTranscriptUpdate? {
        guard data.first == UInt8(ascii: "{") else { return nil }
        let message = try JSONDecoder().decode(InboundMessage.self, from: data)

        switch message.type {
        case "transcript.created":
            return GrokTranscriptUpdate(
                transcript: .empty,
                state: state,
                serverReady: true
            )

        case "transcript.partial":
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }

            let isFinal = message.isFinal ?? false
            let speechFinal = message.speechFinal ?? false

            if !isFinal {
                let confirmed = state.joinedConfirmed
                let partialOnly = stripConfirmedPrefix(from: text, confirmed: confirmed)
                guard !partialOnly.isEmpty else { return nil }
                let normalized = normalize(segment: partialOnly, after: confirmed)
                let segments = state.confirmedSegments
                let transcript = RecognitionTranscript(
                    confirmedSegments: segments,
                    partialText: normalized,
                    authoritativeText: (segments + [normalized]).joined(),
                    isFinal: false
                )
                return GrokTranscriptUpdate(
                    transcript: transcript,
                    state: state,
                    serverReady: false
                )
            }

            if speechFinal {
                let next = commitSpeechFinal(text, state: state)
                let dedupedText = polishTranscript(next.joinedConfirmed)
                let finalState = GrokTranscriptState(
                    utterances: dedupedText == next.joinedConfirmed ? next.utterances : [dedupedText],
                    currentChunks: []
                )
                let transcript = RecognitionTranscript(
                    confirmedSegments: finalState.confirmedSegments,
                    partialText: "",
                    authoritativeText: dedupedText,
                    isFinal: isFinalCommit
                )
                return GrokTranscriptUpdate(
                    transcript: transcript,
                    state: finalState,
                    serverReady: false
                )
            }

            let next = appendChunk(text, to: state)
            let transcript = RecognitionTranscript(
                confirmedSegments: next.confirmedSegments,
                partialText: "",
                authoritativeText: next.joinedConfirmed,
                isFinal: false
            )
            return GrokTranscriptUpdate(
                transcript: transcript,
                state: next,
                serverReady: false
            )

        case "transcript.done":
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                let joined = state.joinedConfirmed
                guard !joined.isEmpty else { return nil }
                let transcript = RecognitionTranscript(
                    confirmedSegments: state.confirmedSegments,
                    partialText: "",
                    authoritativeText: joined,
                    isFinal: isFinalCommit
                )
                return GrokTranscriptUpdate(
                    transcript: transcript,
                    state: state,
                    serverReady: false
                )
            }

            let next = finalizeSessionDone(text, state: state)
            let transcript = RecognitionTranscript(
                confirmedSegments: next.confirmedSegments,
                partialText: "",
                authoritativeText: next.joinedConfirmed,
                isFinal: isFinalCommit
            )
            return GrokTranscriptUpdate(
                transcript: transcript,
                state: next,
                serverReady: false
            )

        case "error":
            throw GrokProtocolError.serverError(message: message.message ?? "")

        default:
            return nil
        }
    }

    // MARK: - State transitions

    fileprivate static func flattenSegments(utterances: [String], currentChunks: [String]) -> [String] {
        if currentChunks.isEmpty { return utterances }
        if utterances.isEmpty { return currentChunks }
        var chunks = currentChunks
        chunks[0] = normalize(segment: chunks[0], after: utterances.joined())
        return utterances + chunks
    }

    private static func appendChunk(_ chunk: String, to state: GrokTranscriptState) -> GrokTranscriptState {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return state }

        var chunks = state.currentChunks
        let joined = chunks.joined()
        if joined.isEmpty {
            chunks = [trimmed]
        } else if joined == trimmed || joined.hasSuffix(trimmed) {
            // no-op
        } else if isNearDuplicate(trimmed, of: joined) {
            // no-op
        } else {
            chunks.append(normalize(segment: trimmed, after: state.utterances.joined() + joined))
        }
        return GrokTranscriptState(utterances: state.utterances, currentChunks: chunks)
    }

    /// `speech_final` commits the current utterance. Revise the last utterance when xAI
    /// sends a longer/corrected take; otherwise append a new sentence.
    private static func commitSpeechFinal(_ text: String, state: GrokTranscriptState) -> GrokTranscriptState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return GrokTranscriptState(utterances: state.utterances, currentChunks: [])
        }

        var utterances = state.utterances
        let chunkText = state.currentChunks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let utteranceText = commitUtteranceFromChunks(trimmed, chunkText: chunkText)

        if let last = utterances.last, isNearDuplicateEcho(utteranceText, of: last) {
            // duplicate echo — keep existing
        } else if let last = utterances.last, isFullUtteranceRetake(utteranceText, of: last) {
            utterances[utterances.count - 1] = utteranceText
        } else if let last = utterances.last,
                  shouldReviseUtterance(utteranceText, previousUtterance: last, pendingChunks: "") {
            utterances[utterances.count - 1] = preferBetterUtterance(utteranceText, over: last)
        } else if let last = utterances.last, isNearDuplicate(utteranceText, of: last) {
            // duplicate echo — keep existing
        } else if utterances.isEmpty {
            utterances = [utteranceText]
        } else {
            utterances.append(normalize(segment: utteranceText, after: utterances.joined()))
        }

        return GrokTranscriptState(utterances: utterances, currentChunks: [])
    }

    /// Merge pending chunk finals with a `speech_final` clause. xAI sometimes finalizes only
    /// the tail while earlier words remain in chunk finals.
    private static func commitUtteranceFromChunks(_ trimmed: String, chunkText: String) -> String {
        guard !chunkText.isEmpty else { return trimmed }

        if trimmed.hasPrefix(chunkText) || isUtteranceRevision(trimmed, of: chunkText) {
            return trimmed
        }
        if chunkText.hasPrefix(trimmed) || isNearDuplicate(trimmed, of: chunkText) {
            return chunkText
        }

        return chunkText + normalize(segment: trimmed, after: chunkText)
    }

    private static func finalizeSessionDone(_ text: String, state: GrokTranscriptState) -> GrokTranscriptState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return state }

        let joined = state.joinedConfirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.isEmpty {
            return GrokTranscriptState(utterances: [polishTranscript(trimmed)], currentChunks: [])
        }

        if trimmed == joined {
            return GrokTranscriptState(utterances: [joined], currentChunks: [])
        }

        if isNearDuplicate(trimmed, of: joined) {
            let deduped = polishTranscript(joined)
            return GrokTranscriptState(utterances: [deduped], currentChunks: [])
        }

        if trimmed.hasPrefix(joined) {
            let suffix = String(trimmed.dropFirst(joined.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if suffix.isEmpty || isNearDuplicateEcho(suffix, of: joined) || isNearDuplicate(suffix, of: joined) {
                return GrokTranscriptState(utterances: [joined], currentChunks: [])
            }
        }

        if trimmed.count < joined.count,
           normalizedForDedup(joined).contains(normalizedForDedup(trimmed)) || joined.hasSuffix(trimmed) {
            return GrokTranscriptState(utterances: [polishTranscript(joined)], currentChunks: [])
        }

        if trimmed.count >= joined.count {
            return GrokTranscriptState(utterances: [polishTranscript(trimmed)], currentChunks: [])
        }

        return GrokTranscriptState(utterances: state.utterances + [normalize(segment: trimmed, after: joined)], currentChunks: [])
    }

    // MARK: - Dedup helpers

    private static func shouldReviseUtterance(
        _ candidate: String,
        previousUtterance: String,
        pendingChunks: String
    ) -> Bool {
        let prev = previousUtterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prev.isEmpty else { return false }

        if isNearDuplicate(candidate, of: prev) { return false }
        if isUtteranceRevision(candidate, of: prev) { return true }

        if !pendingChunks.isEmpty, isUtteranceRevision(candidate, of: pendingChunks) {
            return true
        }

        return false
    }

    /// Detect when xAI sends a second full take of the same monologue with minor edits.
    private static func isFullUtteranceRetake(_ candidate: String, of previous: String) -> Bool {
        if isNearDuplicateEcho(candidate, of: previous) { return false }
        let candWords = collapsedNormalizedWords(candidate)
        let prevWords = collapsedNormalizedWords(previous)
        guard candWords.count >= 6, prevWords.count >= 6 else { return false }

        guard openingWordsMatch(candWords, prevWords, count: 3) else { return false }

        return wordOverlapRatio(candWords, prevWords) >= 0.55
    }

    private static func collapsedNormalizedWords(_ text: String) -> [String] {
        var collapsed: [String] = []
        for word in normalizedWords(text) {
            if collapsed.last == word { continue }
            collapsed.append(word)
        }
        return collapsed
    }

    private static func openingWordsMatch(_ a: [String], _ b: [String], count: Int) -> Bool {
        guard a.count >= count, b.count >= count else { return false }
        return zip(a.prefix(count), b.prefix(count)).allSatisfy { fuzzyWordEqual($0, $1) }
    }

    /// Trivial echo with only formatting or one-word drift — keep the first take.
    private static func isNearDuplicateEcho(_ candidate: String, of previous: String) -> Bool {
        guard isNearDuplicate(candidate, of: previous) else { return false }
        let candWords = normalizedWords(candidate)
        let prevWords = normalizedWords(previous)
        guard abs(candWords.count - prevWords.count) <= 2 else { return false }
        return wordOverlapRatio(candWords, prevWords) >= 0.95
    }

    private static func normalizedWords(_ text: String) -> [String] {
        normalizedForDedup(text).split(separator: " ").map(String.init)
    }

    private static func wordOverlapRatio(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let setA = Set(a)
        let setB = Set(b)
        return Double(setA.intersection(setB).count) / Double(setA.union(setB).count)
    }

    private static func preferBetterUtterance(_ a: String, over b: String) -> String {
        let aNorm = normalizedForDedup(a)
        let bNorm = normalizedForDedup(b)
        if aNorm.count != bNorm.count {
            return aNorm.count > bNorm.count ? a : b
        }
        return a.count >= b.count ? a : b
    }

    /// Detect when a new `speech_final` extends or corrects a prior take of the same pause.
    private static func isUtteranceRevision(_ candidate: String, of previous: String) -> Bool {
        let cand = normalizedForDedup(candidate)
        let prev = normalizedForDedup(previous)
        guard !cand.isEmpty, !prev.isEmpty else { return false }

        if cand.hasPrefix(prev) || prev.hasPrefix(cand) { return true }

        let prevWords = prev.split(separator: " ").map(String.init)
        let candWords = cand.split(separator: " ").map(String.init)
        guard prevWords.count >= 2, candWords.count >= 2 else { return false }

        let maxOverlap = min(prevWords.count, candWords.count)
        for size in stride(from: maxOverlap, through: 2, by: -1) {
            let prevSuffix = prevWords.suffix(size)
            let candPrefix = candWords.prefix(size)
            if zip(prevSuffix, candPrefix).allSatisfy({ fuzzyWordEqual($0, $1) }) {
                return true
            }
        }
        return false
    }

    private static func fuzzyWordEqual(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if isNearDuplicate(lhs, of: rhs) { return true }
        return false
    }

    private static func normalizedForDedup(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isNearDuplicate(_ candidate: String, of existing: String) -> Bool {
        let normalizedCandidate = normalizedForDedup(candidate)
        let normalizedExisting = normalizedForDedup(existing)
        guard !normalizedCandidate.isEmpty, !normalizedExisting.isEmpty else { return false }
        if normalizedCandidate == normalizedExisting { return true }

        let shorter = min(normalizedCandidate.count, normalizedExisting.count)
        let longer = max(normalizedCandidate.count, normalizedExisting.count)
        guard shorter > 0 else { return false }

        if normalizedCandidate.contains(normalizedExisting) || normalizedExisting.contains(normalizedCandidate) {
            return Double(shorter) / Double(longer) >= 0.85
        }
        return false
    }

    /// Dedup overlapping phrases and repair orphan periods from chunk boundaries.
    static func polishTranscript(_ text: String) -> String {
        repairOrphanTerminalPeriods(dedupeOverlappingPhrases(text))
    }

    /// Remove repeated sentences and near-duplicate clauses from a final payload.
    static func dedupeOverlappingPhrases(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let withoutRestart = dedupeFullUtteranceRestarts(trimmed)
        let rawParts = withoutRestart.split(
            whereSeparator: { $0 == "." || $0 == "?" || $0 == "!" }
        ).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard rawParts.count >= 2 else {
            return dedupeRepeatedWordSequences(withoutRestart)
        }

        var sentences: [String] = []
        for part in rawParts where !part.isEmpty {
            let sentence = dedupeRepeatedWordSequences(part) + "."
            if let last = sentences.last, isNearDuplicate(sentence, of: last) || isUtteranceRevision(sentence, of: last) {
                if normalizedForDedup(sentence).count > normalizedForDedup(last).count {
                    sentences[sentences.count - 1] = sentence
                }
                continue
            }
            sentences.append(sentence)
        }

        var deduped = sentences.joined(separator: " ")
        deduped = dedupeRepeatedClauses(in: deduped)
        return deduped
    }

    private static func dedupeFullUtteranceRestarts(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 8 else { return text }

        for i in 3..<words.count {
            let head = words[0..<i].joined(separator: " ")
            let headWordCount = collapsedNormalizedWords(head).count
            guard words.count > i + 3 else { continue }

            let maxRetakeWords = min(headWordCount + 5, words.count - i)
            for retakeWordCount in stride(from: maxRetakeWords, through: max(3, headWordCount - 2), by: -1) {
                let retakeEnd = i + retakeWordCount
                guard retakeEnd <= words.count else { continue }
                let retake = words[i..<retakeEnd].joined(separator: " ")
                if isFullUtteranceRetake(retake, of: head) {
                    return words[i...].joined(separator: " ")
                }
            }
        }

        let collapsed = collapsedNormalizedWords(words.joined(separator: " "))
        let openingSize = 3
        for i in openingSize..<collapsed.count {
            guard openingWordsMatch(Array(collapsed[i...]), collapsed, count: openingSize) else { continue }

            var wordIndex = 0
            var collapsedIndex = 0
            while wordIndex < words.count, collapsedIndex < i {
                let token = normalizedForDedup(words[wordIndex])
                if !token.isEmpty {
                    collapsedIndex += 1
                }
                wordIndex += 1
            }
            guard wordIndex < words.count else { continue }

            let head = words[0..<wordIndex].joined(separator: " ")
            let tail = words[wordIndex...].joined(separator: " ")
            guard collapsedNormalizedWords(head).count >= 6, collapsedNormalizedWords(tail).count >= 6 else { continue }
            if isFullUtteranceRetake(tail, of: head) {
                return tail
            }
            if isNearDuplicateEcho(tail, of: head) {
                return preferBetterUtterance(head, over: tail)
            }
        }

        return text
    }

    private static func dedupeRepeatedWordSequences(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 6 else { return text }

        for i in 1..<words.count {
            for j in 0..<i {
                guard fuzzyWordEqual(words[i], words[j]) else { continue }

                var overlap = 0
                while i + overlap < words.count,
                      j + overlap < i,
                      fuzzyWordEqual(words[i + overlap], words[j + overlap]) {
                    overlap += 1
                }

                guard overlap >= 3 else { continue }

                words.removeSubrange(j..<i)
                return dedupeRepeatedWordSequences(words.joined(separator: " "))
            }
        }

        return words.joined(separator: " ")
    }

    private static func dedupeRepeatedClauses(in text: String) -> String {
        let clauses = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard clauses.count >= 2 else { return text }

        var result: [String] = []
        for clause in clauses where !clause.isEmpty {
            if let last = result.last,
               isNearDuplicate(clause, of: last) || isUtteranceRevision(clause, of: last) {
                if normalizedForDedup(clause).count > normalizedForDedup(last).count {
                    result[result.count - 1] = clause
                }
                continue
            }
            result.append(clause)
        }
        return result.joined(separator: ", ")
    }

    /// xAI chunk finals often end conjunctions/prepositions with a stray period before continuation.
    private static func repairOrphanTerminalPeriods(_ text: String) -> String {
        let pattern = #"\b(and|or|in|to|with|for|but|as|at|on)\.\s+"#
        return text.replacingOccurrences(
            of: pattern,
            with: "$1 ",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func jsonString(_ payload: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
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
