import AppKit
import ApplicationServices
import Foundation

struct CorrectionObservationContext: @unchecked Sendable {
    let element: AXUIElement
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let baselineValue: String
    let injectedRange: NSRange
    let beforeSelectedRange: NSRange?
    let afterSelectedRange: NSRange?
    let injectedText: String
    let sourceRecordID: String
    let modeID: UUID
}

struct TrackedInjectionResult: @unchecked Sendable {
    let outcome: InjectionOutcome
    let observationContext: CorrectionObservationContext?
}

struct CorrectionCandidate: Equatable, Sendable {
    let wrongText: String
    let correctedText: String
    let sourceRecordID: String
    let bundleIdentifier: String
}

enum CorrectionDiffRejection: String, Equatable, Sendable {
    case unchanged
    case invalidRange
    case noChangeInsideInjection
    case multipleChanges
    case pureInsertionOrDeletion
    case ambiguousCJKReplacement
    case invalidCandidate
    case sensitiveContent
}

enum CorrectionDiffResult: Equatable, Sendable {
    case candidate(wrongText: String, correctedText: String)
    case rejected(CorrectionDiffRejection)
}

/// Pure, deterministic analysis of changes made after Type4Me injected text.
enum CorrectionDiffAnalyzer {
    private struct EditHunk {
        var oldStart: Int
        var oldEnd: Int
        var newStart: Int
        var newEnd: Int
    }

    static func analyze(
        baseline: String,
        injectedRange: NSRange,
        current: String
    ) -> CorrectionDiffResult {
        guard baseline != current else { return .rejected(.unchanged) }
        guard let baselineRange = Range(injectedRange, in: baseline) else {
            return .rejected(.invalidRange)
        }

        let old = Array(baseline)
        let new = Array(current)
        let injectionStart = baseline.distance(from: baseline.startIndex, to: baselineRange.lowerBound)
        let injectionEnd = baseline.distance(from: baseline.startIndex, to: baselineRange.upperBound)

        guard let hunks = editHunks(old: old, new: new) else {
            return .rejected(.multipleChanges)
        }

        let inside = hunks.filter { hunk in
            if hunk.oldStart == hunk.oldEnd {
                return hunk.oldStart > injectionStart && hunk.oldStart < injectionEnd
            }
            return hunk.oldStart < injectionEnd && hunk.oldEnd > injectionStart
        }
        guard !inside.isEmpty else { return .rejected(.noChangeInsideInjection) }
        guard var hunk = mergedLexicalHunk(inside, old: old, new: new) else {
            return .rejected(.multipleChanges)
        }

        if isSensitiveChange(in: baseline, characterRange: hunk.oldStart..<hunk.oldEnd)
            || isSensitiveChange(in: current, characterRange: hunk.newStart..<hunk.newEnd) {
            return .rejected(.sensitiveContent)
        }

        let rawRemoved = Array(old[hunk.oldStart..<hunk.oldEnd])
        let rawInserted = Array(new[hunk.newStart..<hunk.newEnd])
        if !rawRemoved.isEmpty,
           !rawInserted.isEmpty,
           !(rawRemoved + rawInserted).contains(where: isLearnableCharacter) {
            return .rejected(.invalidCandidate)
        }
        if rawRemoved.isEmpty || rawInserted.isEmpty {
            let changedCharacters = rawRemoved + rawInserted
            if changedCharacters.contains(where: isLearnableCharacter) {
                return .rejected(.pureInsertionOrDeletion)
            }
        }

        let isCJKReplacement = !rawRemoved.isEmpty
            && !rawInserted.isEmpty
            && rawRemoved.allSatisfy(isCJK)
            && rawInserted.allSatisfy(isCJK)

        // A multi-character Chinese replacement already carries a useful word
        // boundary. Expanding it with arbitrary neighboring Han characters is
        // what turned “加好 → 佳豪” into “人的加好程度 → 人的佳豪程度”.
        // A single-character Chinese diff has no reliable word boundary, so V1
        // skips it rather than learning a dangerously broad mapping.
        if isCJKReplacement {
            guard rawRemoved.count >= 2, rawInserted.count >= 2 else {
                return .rejected(.ambiguousCJKReplacement)
            }
        } else if rawRemoved.isEmpty || rawInserted.isEmpty {
            let neighbors = [
                adjacentCharacter(in: old, before: hunk.oldStart),
                adjacentCharacter(in: old, at: hunk.oldEnd),
                adjacentCharacter(in: new, before: hunk.newStart),
                adjacentCharacter(in: new, at: hunk.newEnd),
            ].compactMap { $0 }
            guard neighbors.contains(where: { $0.isLetter || $0.isNumber }),
                  !neighbors.contains(where: isCJK)
            else { return .rejected(.invalidCandidate) }
        }

        let shouldExpandContext = !isCJKReplacement
        let contextLimit = shouldExpandContext ? 32 : 0

        var leftExpansion = 0
        while hunk.oldStart > injectionStart,
              hunk.newStart > 0,
              leftExpansion < contextLimit {
            let oldCharacter = old[hunk.oldStart - 1]
            let newCharacter = new[hunk.newStart - 1]
            guard oldCharacter == newCharacter,
                  shouldExpand(over: oldCharacter, cjkMode: false)
            else { break }
            hunk.oldStart -= 1
            hunk.newStart -= 1
            leftExpansion += 1
        }

        var rightExpansion = 0
        while hunk.oldEnd < injectionEnd,
              hunk.newEnd < new.count,
              rightExpansion < contextLimit {
            let oldCharacter = old[hunk.oldEnd]
            let newCharacter = new[hunk.newEnd]
            guard oldCharacter == newCharacter,
                  shouldExpand(over: oldCharacter, cjkMode: false)
            else { break }
            hunk.oldEnd += 1
            hunk.newEnd += 1
            rightExpansion += 1
        }

        let wrong = String(old[hunk.oldStart..<hunk.oldEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = String(new[hunk.newStart..<hunk.newEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidCandidate(wrong), isValidCandidate(corrected), wrong != corrected else {
            return .rejected(.invalidCandidate)
        }
        guard !isSensitive(wrong), !isSensitive(corrected) else {
            return .rejected(.sensitiveContent)
        }
        return .candidate(wrongText: wrong, correctedText: corrected)
    }

    private static func mergedLexicalHunk(
        _ hunks: [EditHunk],
        old: [Character],
        new: [Character]
    ) -> EditHunk? {
        guard var merged = hunks.first else { return nil }
        for next in hunks.dropFirst() {
            let oldGap = next.oldStart >= merged.oldEnd
                ? Array(old[merged.oldEnd..<next.oldStart])
                : []
            let newGap = next.newStart >= merged.newEnd
                ? Array(new[merged.newEnd..<next.newStart])
                : []
            let gapIsWithinOneLexicalUnit = oldGap.count <= 4
                && newGap.count <= 4
                && oldGap.allSatisfy(isLearnableCharacter)
                && newGap.allSatisfy(isLearnableCharacter)
            guard gapIsWithinOneLexicalUnit else { return nil }
            merged.oldEnd = max(merged.oldEnd, next.oldEnd)
            merged.newEnd = max(merged.newEnd, next.newEnd)
        }
        return merged
    }

    private static func editHunks(old: [Character], new: [Character]) -> [EditHunk]? {
        let difference = new.difference(from: old)
        let removals = Set(difference.compactMap { change -> Int? in
            guard case .remove(let offset, _, _) = change else { return nil }
            return offset
        })
        let insertions = Set(difference.compactMap { change -> Int? in
            guard case .insert(let offset, _, _) = change else { return nil }
            return offset
        })

        var oldIndex = 0
        var newIndex = 0
        var hunks: [EditHunk] = []
        var active: EditHunk?

        func flush() {
            if let active {
                hunks.append(active)
            }
            active = nil
        }

        while oldIndex < old.count || newIndex < new.count {
            var edited = false
            if newIndex < new.count, insertions.contains(newIndex) {
                if active == nil {
                    active = EditHunk(
                        oldStart: oldIndex, oldEnd: oldIndex,
                        newStart: newIndex, newEnd: newIndex
                    )
                }
                active?.newEnd = newIndex + 1
                newIndex += 1
                edited = true
            }
            if oldIndex < old.count, removals.contains(oldIndex) {
                if active == nil {
                    active = EditHunk(
                        oldStart: oldIndex, oldEnd: oldIndex,
                        newStart: newIndex, newEnd: newIndex
                    )
                }
                active?.oldEnd = oldIndex + 1
                oldIndex += 1
                edited = true
            }
            if edited { continue }

            guard oldIndex < old.count, newIndex < new.count, old[oldIndex] == new[newIndex] else {
                return nil
            }
            flush()
            oldIndex += 1
            newIndex += 1
        }
        flush()
        return hunks
    }

    private static func adjacentCharacter(in characters: [Character], before index: Int) -> Character? {
        guard index > 0, index <= characters.count else { return nil }
        return characters[index - 1]
    }

    private static func adjacentCharacter(in characters: [Character], at index: Int) -> Character? {
        guard index >= 0, index < characters.count else { return nil }
        return characters[index]
    }

    private static func shouldExpand(over character: Character, cjkMode: Bool) -> Bool {
        if cjkMode { return isCJK(character) }
        return character.isLetter || character.isNumber || character == "_"
    }

    private static func isLearnableCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || isCJK(character)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    private static func isValidCandidate(_ text: String) -> Bool {
        guard !text.contains("\n"), !text.contains("\r") else { return false }
        guard (2...32).contains(text.count) else { return false }
        guard text.split(whereSeparator: { $0.isWhitespace }).count <= 5 else { return false }
        return text.contains(where: isLearnableCharacter)
    }

    private static func isSensitive(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("://") || lowered.hasPrefix("www.") { return true }
        if matches(#"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#, in: text) { return true }
        if matches(#"(?:\d[\s-]?){7,}"#, in: text) { return true }
        if matches(#"\b(?=[A-Za-z0-9_-]{20,}\b)(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]+\b"#, in: text) {
            return true
        }
        return false
    }

    private static func isSensitiveChange(in text: String, characterRange: Range<Int>) -> Bool {
        let characters = Array(text)
        guard characterRange.lowerBound >= 0,
              characterRange.upperBound <= characters.count
        else { return true }
        let lowerIndex = text.index(text.startIndex, offsetBy: characterRange.lowerBound)
        let upperIndex = text.index(text.startIndex, offsetBy: characterRange.upperBound)
        let changedRange = NSRange(lowerIndex..<upperIndex, in: text)
        let patterns = [
            #"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#,
            #"(?:https?://|www\.)\S+"#,
            #"(?:\d[\s-]?){7,}"#,
            #"\b(?=[A-Za-z0-9_-]{20,}\b)(?=[A-Za-z0-9_-]*[A-Za-z])(?=[A-Za-z0-9_-]*\d)[A-Za-z0-9_-]+\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: fullRange) {
                if changedRange.length == 0 {
                    if changedRange.location >= match.range.location,
                       changedRange.location <= NSMaxRange(match.range) {
                        return true
                    }
                } else if NSIntersectionRange(changedRange, match.range).length > 0 {
                    return true
                }
            }
        }
        return false
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

struct CorrectionMapping: Equatable, Sendable {
    let trigger: String
    let replacement: String
}

protocol CorrectionVocabularyPersisting {
    func loadHotwords() -> [String]
    func loadMappings() -> [CorrectionMapping]
    func saveHotwords(_ words: [String]) throws
    func saveMappings(_ mappings: [CorrectionMapping]) throws
}

struct Type4MeCorrectionVocabularyPersistence: CorrectionVocabularyPersisting {
    func loadHotwords() -> [String] { HotwordStorage.load() }
    func loadMappings() -> [CorrectionMapping] {
        SnippetStorage.load().map { CorrectionMapping(trigger: $0.trigger, replacement: $0.value) }
    }
    func saveHotwords(_ words: [String]) throws { try HotwordStorage.saveOrThrow(words) }
    func saveMappings(_ mappings: [CorrectionMapping]) throws {
        try SnippetStorage.saveOrThrow(mappings.map { (trigger: $0.trigger, value: $0.replacement) })
    }
}

struct CorrectionLearningStore {
    let persistence: any CorrectionVocabularyPersisting

    init(persistence: any CorrectionVocabularyPersisting = Type4MeCorrectionVocabularyPersistence()) {
        self.persistence = persistence
    }

    func learn(_ candidate: CorrectionCandidate) throws {
        let oldHotwords = persistence.loadHotwords()
        let oldMappings = persistence.loadMappings()

        var newHotwords = oldHotwords
        if !newHotwords.contains(where: { $0.caseInsensitiveCompare(candidate.correctedText) == .orderedSame }) {
            newHotwords.append(candidate.correctedText)
        }

        var newMappings = oldMappings
        if let index = newMappings.firstIndex(where: {
            $0.trigger.caseInsensitiveCompare(candidate.wrongText) == .orderedSame
        }) {
            newMappings[index] = CorrectionMapping(
                trigger: candidate.wrongText,
                replacement: candidate.correctedText
            )
        } else {
            newMappings.append(CorrectionMapping(
                trigger: candidate.wrongText,
                replacement: candidate.correctedText
            ))
        }

        let hotwordsChanged = newHotwords != oldHotwords
        let mappingsChanged = newMappings != oldMappings
        guard hotwordsChanged || mappingsChanged else { return }

        do {
            if hotwordsChanged { try persistence.saveHotwords(newHotwords) }
            do {
                if mappingsChanged { try persistence.saveMappings(newMappings) }
            } catch {
                if hotwordsChanged { try? persistence.saveHotwords(oldHotwords) }
                throw error
            }
        } catch {
            throw error
        }
    }
}

@MainActor
final class CorrectionLearningCoordinator {
    static let shared = CorrectionLearningCoordinator()

    nonisolated static let enabledDefaultsKey = "tf_autoCorrectionLearningEnabled"
    nonisolated static let observationDuration: Duration = .seconds(60)
    nonisolated static let debounceDuration: Duration = .seconds(4)

    private struct ActiveObservation {
        let context: CorrectionObservationContext
        let observer: AXObserver
        let observesElementDestruction: Bool
    }

    private var active: ActiveObservation?
    private var timeoutTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private lazy var panelController = CorrectionLearningPanelController()
    private let learningStore = CorrectionLearningStore()

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    static func supports(modeID: UUID) -> Bool {
        modeID == ProcessingMode.directId || modeID == ProcessingMode.formalWritingId
    }

    func begin(_ context: CorrectionObservationContext) {
        cancelObservation()
        guard Self.isEnabled, Self.supports(modeID: context.modeID) else { return }

        var observer: AXObserver?
        let createStatus = AXObserverCreate(context.processIdentifier, correctionAXObserverCallback, &observer)
        guard createStatus == .success, let observer else {
            DebugFileLogger.log("correction observer skipped: create status=\(createStatus.rawValue) bundle=\(context.bundleIdentifier)")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addStatus = AXObserverAddNotification(
            observer,
            context.element,
            kAXValueChangedNotification as CFString,
            refcon
        )
        guard addStatus == .success else {
            DebugFileLogger.log("correction observer skipped: add status=\(addStatus.rawValue) bundle=\(context.bundleIdentifier)")
            return
        }

        let destructionStatus = AXObserverAddNotification(
            observer,
            context.element,
            kAXUIElementDestroyedNotification as CFString,
            refcon
        )

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            CFRunLoopMode.commonModes
        )
        active = ActiveObservation(
            context: context,
            observer: observer,
            observesElementDestruction: destructionStatus == .success
        )
        DebugFileLogger.log("correction observer started: bundle=\(context.bundleIdentifier) injectedLength=\(context.injectedText.count)")

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.observationDuration)
            guard !Task.isCancelled else { return }
            self?.cancelObservation()
        }
    }

    func cancelObservation() {
        timeoutTask?.cancel()
        debounceTask?.cancel()
        timeoutTask = nil
        debounceTask = nil
        if let active {
            AXObserverRemoveNotification(
                active.observer,
                active.context.element,
                kAXValueChangedNotification as CFString
            )
            if active.observesElementDestruction {
                AXObserverRemoveNotification(
                    active.observer,
                    active.context.element,
                    kAXUIElementDestroyedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(active.observer),
                CFRunLoopMode.commonModes
            )
        }
        active = nil
        panelController.hide()
    }

    fileprivate func accessibilityValueDidChange(element: AXUIElement) {
        guard let active, CFEqual(active.context.element, element) else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDuration)
            guard !Task.isCancelled else { return }
            self?.analyzeCurrentValue()
        }
    }

    fileprivate func accessibilityElementWasDestroyed(element: AXUIElement) {
        guard let active, CFEqual(active.context.element, element) else { return }
        cancelObservation()
    }

    private func analyzeCurrentValue() {
        guard let active else { return }
        guard let currentValue = copyStringAttribute(kAXValueAttribute as CFString, from: active.context.element) else {
            DebugFileLogger.log("correction observer stopped: unreadable value bundle=\(active.context.bundleIdentifier)")
            cancelObservation()
            return
        }
        guard !currentValue.isEmpty else {
            cancelObservation()
            return
        }

        switch CorrectionDiffAnalyzer.analyze(
            baseline: active.context.baselineValue,
            injectedRange: active.context.injectedRange,
            current: currentValue
        ) {
        case .candidate(let wrongText, let correctedText):
            let candidate = CorrectionCandidate(
                wrongText: wrongText,
                correctedText: correctedText,
                sourceRecordID: active.context.sourceRecordID,
                bundleIdentifier: active.context.bundleIdentifier
            )
            stopObservingWithoutHidingPanel()
            panelController.show(
                candidate: candidate,
                onLearn: { [weak self] in self?.learn(candidate) },
                onIgnore: { [weak self] in self?.cancelObservation() }
            )
        case .rejected(let reason):
            DebugFileLogger.log("correction candidate rejected: reason=\(reason.rawValue) bundle=\(active.context.bundleIdentifier)")
        }
    }

    private func learn(_ candidate: CorrectionCandidate) {
        do {
            try learningStore.learn(candidate)
            panelController.showLearned()
        } catch {
            DebugFileLogger.log("correction learning save failed: bundle=\(candidate.bundleIdentifier) error=\(error.localizedDescription)")
            panelController.showSaveFailure()
        }
    }

    private func stopObservingWithoutHidingPanel() {
        timeoutTask?.cancel()
        debounceTask?.cancel()
        timeoutTask = nil
        debounceTask = nil
        if let active {
            AXObserverRemoveNotification(
                active.observer,
                active.context.element,
                kAXValueChangedNotification as CFString
            )
            if active.observesElementDestruction {
                AXObserverRemoveNotification(
                    active.observer,
                    active.context.element,
                    kAXUIElementDestroyedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(active.observer),
                CFRunLoopMode.commonModes
            )
        }
        active = nil
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}

private let correctionAXObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let coordinator = Unmanaged<CorrectionLearningCoordinator>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    Task { @MainActor in
        switch notification as String {
        case kAXValueChangedNotification:
            coordinator.accessibilityValueDidChange(element: element)
        case kAXUIElementDestroyedNotification:
            coordinator.accessibilityElementWasDestroyed(element: element)
        default:
            break
        }
    }
}
