import XCTest
@testable import Type4Me

@MainActor
final class AppStateTests: XCTestCase {

    func testStartRecordingTransitionsToPreparing() {
        let appState = AppState()
        appState.startRecording()

        XCTAssertEqual(appState.barPhase, .preparing)
    }

    func testStopRecordingIgnoredWhenNotRecording() {
        let appState = AppState()
        appState.currentMode = .smartDirect
        appState.cancel()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .hidden)
    }

    func testStopRecordingCancelsWhenPreparing() {
        let appState = AppState()
        appState.startRecording()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .hidden)
    }

    func testStopRecordingTransitionsToProcessingWhenRecording() {
        let appState = AppState()
        appState.currentMode = .smartDirect
        appState.startRecording()
        appState.markRecordingReady()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
    }

    func testStopRecordingTransitionsDirectModeToProcessing() {
        let appState = AppState()
        appState.currentMode = .direct
        appState.startRecording()
        appState.markRecordingReady()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
    }

    func testShowRecoveryDisplaysPartialTextAndStatus() {
        let appState = AppState()

        appState.showRecovery(
            text: "已经识别的文字",
            message: "连接中断，已保留当前文字，正在用整段录音重试"
        )

        XCTAssertEqual(appState.barPhase, .recovering)
        XCTAssertEqual(appState.transcriptionText, "已经识别的文字")
        XCTAssertEqual(appState.effectiveProcessingLabel, "连接中断，已保留当前文字，正在用整段录音重试")
    }

    func testRecoveryPromptKeepsPartialTextVisible() {
        let appState = AppState()
        appState.showRecovery(
            text: "已经识别的文字",
            message: "连接中断，已保留当前文字，正在用整段录音重试"
        )

        appState.showRecoveryPrompt(
            text: "已经识别的文字",
            message: "正在恢复上一次识别。继续按下将打断当前恢复并重新开始录音。"
        )

        XCTAssertEqual(appState.barPhase, .recovering)
        XCTAssertEqual(appState.transcriptionText, "已经识别的文字")
        XCTAssertEqual(appState.effectiveProcessingLabel, "正在恢复上一次识别。继续按下将打断当前恢复并重新开始录音。")
    }

    func testRecoveryResultPinsTranscriptPopup() {
        let appState = AppState()

        appState.showRecoveryResult(text: "完整识别文字", message: "已恢复完整识别")

        XCTAssertEqual(appState.barPhase, .done)
        XCTAssertEqual(appState.transcriptionText, "完整识别文字")
        XCTAssertTrue(appState.pinsTranscriptPopup)
    }

    func testHiddenRecordingVisualKeepsHostPanelAliveForLivePreferenceChanges() {
        let previousStyle = UserDefaults.standard.string(forKey: RecordingVisualStyle.storageKey)
        UserDefaults.standard.set(RecordingVisualStyle.hidden.rawValue, forKey: RecordingVisualStyle.storageKey)
        defer {
            if let previousStyle {
                UserDefaults.standard.set(previousStyle, forKey: RecordingVisualStyle.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RecordingVisualStyle.storageKey)
            }
        }

        let appState = AppState()
        var showCount = 0
        var hideCount = 0
        appState.onShowPanel = { showCount += 1 }
        appState.onHidePanel = { hideCount += 1 }

        appState.startRecording()
        appState.markRecordingReady()

        XCTAssertEqual(appState.barPhase, .recording)
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(hideCount, 0)

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
        XCTAssertEqual(showCount, 2)
        XCTAssertEqual(hideCount, 0)
    }

    func testRecordingVisualStylesIncludeEffectlessAndHiddenAsDistinctChoices() {
        XCTAssertEqual(RecordingVisualStyle.allCases.count, 5)
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.effectless))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.hidden))
        XCTAssertTrue(RecordingVisualStyle.effectless.showsRecordingPanel)
        XCTAssertFalse(RecordingVisualStyle.effectless.showsBackgroundEffect)
        XCTAssertFalse(RecordingVisualStyle.hidden.showsRecordingPanel)
        XCTAssertFalse(RecordingVisualStyle.hidden.showsBackgroundEffect)
    }

    func testFloatingIndicatorDesignDimensionsMatchSpecification() {
        XCTAssertEqual(TF.barHeight, 55)
        XCTAssertEqual(TF.barWidthCompact, 180)
        XCTAssertEqual(TF.barWidth, 400)
        XCTAssertEqual(TF.recordingControlSize, 45)
        XCTAssertEqual(TF.transcriptPopupWidth, 350)
        XCTAssertEqual(TF.transcriptPopupMaxHeight, 120)
        XCTAssertEqual(TF.transcriptPopupCorner, 10)
        XCTAssertEqual(TF.transcriptPopupGap, 10)
    }

    func testFloatingIndicatorHoverTrackingDoesNotInterceptControls() {
        let panel = FloatingBarPanel(contentRect: NSRect(x: 0, y: 0, width: 432, height: 217))
        let tracker = HoverTrackingNSView(frame: NSRect(x: 0, y: 0, width: 45, height: 45))
        let buttonTarget = FloatingBarButtonNSView(frame: NSRect(x: 0, y: 0, width: 45, height: 45))
        var clickCount = 0
        buttonTarget.onClick = { clickCount += 1 }

        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.acceptsMouseMovedEvents)
        XCTAssertNil(tracker.hitTest(NSPoint(x: 22, y: 22)))
        XCTAssertTrue(buttonTarget.acceptsFirstMouse(for: nil))
        XCTAssertTrue(buttonTarget.hitTest(NSPoint(x: 22, y: 22)) === buttonTarget)

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 22, y: 22),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        buttonTarget.mouseDown(with: try! XCTUnwrap(event))
        XCTAssertEqual(clickCount, 1)
    }

    func testFloatingIndicatorActionCallbacksAreForwarded() {
        let appState = AppState()
        var actions: [RecordingControlAction] = []
        appState.onRecordingControlAction = { actions.append($0) }

        appState.performRecordingControlAction(.finish)
        appState.performRecordingControlAction(.cancel)

        XCTAssertEqual(actions, [.finish, .cancel])
    }

    func testDisabledLiveTranscriptOnlyHidesTextWhileRecording() {
        XCTAssertFalse(
            LiveTranscriptDisplayPreference.showsTranscript(
                isEnabled: false,
                phase: .recording
            )
        )
        XCTAssertTrue(
            LiveTranscriptDisplayPreference.showsTranscript(
                isEnabled: false,
                phase: .recovering
            )
        )
        XCTAssertTrue(
            LiveTranscriptDisplayPreference.showsTranscript(
                isEnabled: false,
                phase: .done
            )
        )
    }

    func testEnabledLiveTranscriptShowsTextWhileRecording() {
        XCTAssertTrue(
            LiveTranscriptDisplayPreference.showsTranscript(
                isEnabled: true,
                phase: .recording
            )
        )
    }

    func testSetLiveTranscriptReplacesExistingConfirmedSegments() {
        let appState = AppState()
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["我想", "买咖"],
                partialText: "",
                authoritativeText: "我想买咖",
                isFinal: false
            )
        )
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["我想", "买咖啡"],
                partialText: "",
                authoritativeText: "我想买咖啡",
                isFinal: false
            )
        )

        XCTAssertEqual(appState.segments.map(\.text), ["我想", "买咖啡"])
        XCTAssertEqual(appState.transcriptionText, "我想买咖啡")
    }

    func testSetLiveTranscriptUsesAuthoritativeFinalTextWhenDifferent() {
        let appState = AppState()
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["deep seek"],
                partialText: "",
                authoritativeText: "DeepSeek",
                isFinal: true
            )
        )

        XCTAssertEqual(appState.segments.count, 1)
        XCTAssertEqual(appState.segments.first?.text, "DeepSeek")
        XCTAssertTrue(appState.segments.first?.isConfirmed == true)
    }

    func testSetLiveTranscriptDropsStalePartialUpdates() {
        let appState = AppState()
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["new"],
                partialText: "",
                authoritativeText: "new",
                isFinal: false
            )
        )

        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["old"],
                partialText: "",
                authoritativeText: "old",
                isFinal: false,
                emitTime: ContinuousClock.now - .seconds(1)
            )
        )

        XCTAssertEqual(appState.transcriptionText, "new")
    }

    func testFinalizeShowsClipboardFallbackMessage() {
        let appState = AppState()
        appState.barPhase = .processing

        appState.finalize(text: "测试文本", outcome: .copiedToClipboard)

        XCTAssertEqual(appState.barPhase, .done)
        XCTAssertEqual(appState.feedbackMessage, InjectionOutcome.copiedToClipboard.completionMessage)
        XCTAssertEqual(appState.transcriptionText, "测试文本")
    }

    func testShowErrorDisplaysErrorPhaseAndMessage() {
        let appState = AppState()

        appState.showError("找不到麦克风")

        XCTAssertEqual(appState.barPhase, .error)
        XCTAssertEqual(appState.feedbackMessage, "找不到麦克风")
    }

    func testReconcileCurrentModeKeepsSupportedCustomModeForQuickOnlyProvider() {
        let appState = AppState()
        let customMode = ProcessingMode(
            id: UUID(),
            name: "结构化",
            prompt: "Rewrite {text}",
            isBuiltin: false
        )
        appState.availableModes.append(customMode)
        appState.currentMode = customMode

        appState.reconcileCurrentMode(for: .bailian)

        XCTAssertEqual(appState.currentMode.id, customMode.id)
    }

    func testCrossModeFinishPreferenceDefaultsToDisabled() {
        let suiteName = "CrossModeFinishPreferenceTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(CrossModeFinishPreference.isEnabled(userDefaults: defaults))
    }

    func testCrossModeFinishPreferenceReadsChangesImmediately() {
        let suiteName = "CrossModeFinishPreferenceTests.changes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: CrossModeFinishPreference.storageKey)
        XCTAssertTrue(CrossModeFinishPreference.isEnabled(userDefaults: defaults))

        defaults.set(false, forKey: CrossModeFinishPreference.storageKey)
        XCTAssertFalse(CrossModeFinishPreference.isEnabled(userDefaults: defaults))
    }

    func testCrossModeFinishPreferenceSelectsExpectedProcessingMode() {
        let startingMode = ProcessingMode.direct
        let endingMode = ProcessingMode.smartDirect

        let retainedMode = CrossModeFinishPreference.processingMode(
            startingMode: startingMode,
            endingMode: endingMode,
            isEnabled: false
        )
        XCTAssertEqual(retainedMode.id, startingMode.id)

        let switchedMode = CrossModeFinishPreference.processingMode(
            startingMode: startingMode,
            endingMode: endingMode,
            isEnabled: true
        )
        XCTAssertEqual(switchedMode.id, endingMode.id)
    }

    func testClipboardInjectionPreferencePreservesLegacyInverseStorage() {
        XCTAssertFalse(ClipboardInjectionPreference.isEnabled(preserveClipboard: true))
        XCTAssertTrue(ClipboardInjectionPreference.isEnabled(preserveClipboard: false))
        XCTAssertFalse(ClipboardInjectionPreference.preserveClipboardValue(isEnabled: true))
        XCTAssertTrue(ClipboardInjectionPreference.preserveClipboardValue(isEnabled: false))
    }

    func testLocalASREngineSelectionNeverDisablesBothEngines() {
        let qwenOnly = LocalASREngineSelection(
            senseVoiceEnabled: true,
            qwen3Enabled: false
        ).settingSenseVoice(false, qwen3Available: true)
        XCTAssertEqual(qwenOnly, LocalASREngineSelection(senseVoiceEnabled: false, qwen3Enabled: true))

        let senseVoiceOnly = LocalASREngineSelection(
            senseVoiceEnabled: false,
            qwen3Enabled: true
        ).settingQwen3(false)
        XCTAssertEqual(senseVoiceOnly, LocalASREngineSelection(senseVoiceEnabled: true, qwen3Enabled: false))
    }

    func testLocalASREngineSelectionRejectsLastEngineDisableWhenQwenUnavailable() {
        let selection = LocalASREngineSelection(
            senseVoiceEnabled: true,
            qwen3Enabled: false
        ).settingSenseVoice(false, qwen3Available: false)

        XCTAssertEqual(selection, LocalASREngineSelection(senseVoiceEnabled: true, qwen3Enabled: false))
    }
}
