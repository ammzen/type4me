import AppKit
import SwiftUI

@MainActor
@Observable
final class SelectionAskState {
    struct Turn: Identifiable, Equatable {
        let id = UUID()
        var question: String
        var answer: String
        var isLoading: Bool
        var errorMessage: String?
    }

    enum Phase: Equatable {
        case idle
        case loading
        case answered(String)
        case error(String)
    }

    var question = ""
    var selectedText = ""
    var phase: Phase = .idle
    var turns: [Turn] = []
    var isRecordingFollowUp = false
    var followUpShortcutHint = ""

    /// Whether the answer UI should run its indeterminate loading animation.
    /// Treating `.idle` as loading keeps a hidden, eagerly-created panel
    /// repainting continuously even when Type4Me is otherwise inactive.
    var isAnswerLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var activeAnswer: String {
        switch phase {
        case .answered(let answer):
            return answer
        case .loading, .idle, .error:
            return turns.last?.answer ?? ""
        }
    }
}

enum SelectionAskPromptBuilder {
    enum ContextSource: String {
        case selection
        case none
    }

    static func contextSource(from context: PromptContext) -> ContextSource {
        let selected = context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUsableSelectedText(selected) { return .selection }
        return .none
    }

    static func contextText(from context: PromptContext) -> String {
        switch contextSource(from: context) {
        case .selection:
            return context.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .none:
            return ""
        }
    }

    static func requestText(mode: ProcessingMode, context: PromptContext) -> String {
        context.expandContextVariables(mode.prompt)
    }

    static func requestText(
        mode: ProcessingMode,
        context: PromptContext,
        question: String,
        conversationContext: String = ""
    ) -> String {
        var result = ""
        var remaining = mode.prompt[...]
        let conversationContext = conversationContext.trimmingCharacters(in: .whitespacesAndNewlines)

        while let openRange = remaining.range(of: "{") {
            result += remaining[remaining.startIndex..<openRange.lowerBound]
            remaining = remaining[openRange.lowerBound...]

            if remaining.hasPrefix("{selected}") {
                result += context.selectedText
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 10)...]
            } else if remaining.hasPrefix("{clipboard}") {
                result += context.clipboardText
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 11)...]
            } else if remaining.hasPrefix("{tools_json}") {
                result += ActionRegistry.toolsJSON()
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 12)...]
            } else if remaining.hasPrefix("{conversation}") {
                result += conversationContext
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 14)...]
            } else if remaining.hasPrefix("{text}") {
                result += question
                remaining = remaining[remaining.index(remaining.startIndex, offsetBy: 6)...]
            } else {
                result += "{"
                remaining = remaining[remaining.index(after: remaining.startIndex)...]
            }
        }

        result += remaining
        if !conversationContext.isEmpty, !mode.prompt.contains("{conversation}") {
            result += "\n\n# 上方会话上下文\n```text\n\(conversationContext)\n```"
        }
        return result
    }

    static func isUsableSelectedText(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let placeholders: Set<String> = [
            "selection",
            "selected text",
            "selected",
            "选中文本",
            "所选文本",
        ]
        return !placeholders.contains(normalized)
    }
}

@MainActor
final class SelectionAskPanel: NSPanel {
    var onEscape: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )

        minSize = NSSize(width: 560, height: 440)
        maxSize = NSSize(width: 820, height: 760)
        contentMinSize = minSize
        contentMaxSize = maxSize
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode != 53 else {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class SelectionAskController {
    private let state = SelectionAskState()
    private let panel: SelectionAskPanel
    private var requestGeneration = 0
    private let onStartFollowUp: (String) -> Bool
    private let onFinishFollowUp: () -> Void
    private let onCancelFollowUp: () -> Void
    private var awaitingFollowUpTurn = false

    init(
        onStartFollowUp: @escaping (String) -> Bool = { _ in false },
        onFinishFollowUp: @escaping () -> Void = {},
        onCancelFollowUp: @escaping () -> Void = {}
    ) {
        self.onStartFollowUp = onStartFollowUp
        self.onFinishFollowUp = onFinishFollowUp
        self.onCancelFollowUp = onCancelFollowUp
        let size = NSSize(width: 680, height: 560)
        panel = SelectionAskPanel(contentRect: NSRect(origin: .zero, size: size))

        let view = SelectionAskView(state: state) { [weak self] in
            self?.close()
        } onFollowUp: { [weak self] in
            _ = self?.performPrimaryFollowUpAction()
        } onCancelFollowUp: { [weak self] in
            _ = self?.handleActiveRecordingAction(.cancel)
        }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(NSRect(origin: .zero, size: size), display: false)
        panel.onEscape = { [weak self] in
            self?.handleEscape()
        }
    }

    var isVisible: Bool { panel.isVisible }

    var isRecordingFollowUp: Bool { state.isRecordingFollowUp }
    var turns: [SelectionAskState.Turn] { state.turns }

    func updateFollowUpShortcutHint(_ hint: String) {
        state.followUpShortcutHint = hint
    }

    func begin(question: String, selectedText: String) {
        requestGeneration &+= 1
        state.question = question
        state.selectedText = selectedText
        state.phase = .loading
        state.isRecordingFollowUp = false
        if awaitingFollowUpTurn, !state.turns.isEmpty {
            state.turns.append(SelectionAskState.Turn(question: question, answer: "", isLoading: true))
        } else {
            state.turns = [SelectionAskState.Turn(question: question, answer: "", isLoading: true)]
        }
        awaitingFollowUpTurn = false
        show()
    }

    func appendAnswerDelta(_ delta: String) {
        if !state.turns.isEmpty {
            state.turns[state.turns.count - 1].answer += delta
            state.turns[state.turns.count - 1].isLoading = false
        }
        switch state.phase {
        case .answered(let current):
            state.phase = .answered(current + delta)
        case .loading, .idle:
            state.phase = .answered(delta)
        case .error:
            break
        }
    }

    func completeAnswer() {
        if !state.turns.isEmpty {
            state.turns[state.turns.count - 1].isLoading = false
        }
        if case .loading = state.phase {
            state.phase = .answered("")
        }
    }

    func showError(_ message: String) {
        if !state.turns.isEmpty {
            state.turns[state.turns.count - 1].errorMessage = message
            state.turns[state.turns.count - 1].isLoading = false
        }
        state.phase = .error(message)
    }

    func recordingDidEnd(_ action: RecordingControlAction) {
        guard state.isRecordingFollowUp else { return }
        state.isRecordingFollowUp = false
        if action == .cancel {
            awaitingFollowUpTurn = false
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func close() {
        _ = handleActiveRecordingAction(.cancel)
        hide()
    }

    private func show() {
        positionNearMouse()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    @discardableResult
    func startFollowUpRecording() -> Bool {
        guard !state.isRecordingFollowUp else { return false }
        guard onStartFollowUp(conversationContext()) else { return false }
        awaitingFollowUpTurn = true
        state.isRecordingFollowUp = true
        return true
    }

    @discardableResult
    func finishActiveFollowUp() -> Bool {
        guard state.isRecordingFollowUp else { return false }
        state.isRecordingFollowUp = false
        onFinishFollowUp()
        return true
    }

    @discardableResult
    func cancelActiveFollowUp() -> Bool {
        guard state.isRecordingFollowUp else { return false }
        state.isRecordingFollowUp = false
        awaitingFollowUpTurn = false
        onCancelFollowUp()
        return true
    }

    @discardableResult
    func handleActiveRecordingAction(_ action: RecordingControlAction) -> Bool {
        switch action {
        case .finish:
            return finishActiveFollowUp()
        case .cancel:
            return cancelActiveFollowUp()
        }
    }

    @discardableResult
    func performPrimaryFollowUpAction() -> Bool {
        if state.isRecordingFollowUp {
            return handleActiveRecordingAction(.finish)
        }
        return startFollowUpRecording()
    }

    func handleEscape() {
        guard panel.isVisible else { return }
        if state.isRecordingFollowUp {
            _ = handleActiveRecordingAction(.cancel)
        } else {
            hide()
        }
    }

    private func conversationContext() -> String {
        state.turns.enumerated().map { index, turn in
            let answer = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            第 \(index + 1) 轮
            用户：\(turn.question)
            助手：\(answer.isEmpty ? "（尚无回答）" : answer)
            """
        }.joined(separator: "\n\n")
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let x = visible.midX - frame.width / 2
        let y = visible.midY - frame.height / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
