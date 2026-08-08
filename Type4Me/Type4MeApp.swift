import SwiftUI

@main
struct Type4MeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra(
            "Type4Me",
            systemImage: appDelegate.appState.barPhase == .hidden ? "mic" : "mic.fill"
        ) {
            MenuBarContent()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
        }

        Window(L("Type4Me 设置", "Type4Me Settings"), id: "settings") {
            SettingsView()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)

        Window(L("Type4Me 设置向导", "Type4Me Setup"), id: "setup") {
            SetupWizardView()
                .environment(appDelegate.appState)
                .environment(appDelegate.appUpdater)
                .environment(appDelegate.permissionGuideModel)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)

        Window(L("Type4Me 授权引导", "Type4Me Permissions"), id: "permission-guide") {
            PermissionGuideView(model: appDelegate.permissionGuideModel)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 460, idealHeight: 480)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class RecordingControlCoordinator {
    private weak var followUpController: SelectionAskController?
    private let onStandardAction: (RecordingControlAction) -> Void

    init(
        followUpController: SelectionAskController,
        onStandardAction: @escaping (RecordingControlAction) -> Void
    ) {
        self.followUpController = followUpController
        self.onStandardAction = onStandardAction
    }

    func perform(_ action: RecordingControlAction) {
        if followUpController?.handleActiveRecordingAction(action) == true {
            return
        }
        onStandardAction(action)
    }
}

struct SelectionAskFollowUpStartGate {
    private(set) var generation = 0

    mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func allowsStart(
        token: Int,
        isFollowUpActive: Bool,
        phase: FloatingBarPhase
    ) -> Bool {
        token == generation
            && isFollowUpActive
            && (phase == .preparing || phase == .recording)
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState = AppState()
    let appUpdater = AppUpdater()
    let permissionGuideModel = PermissionGuideModel()
    /// Computed dynamically per recording based on audio device topology.
    private var floatingBarController: FloatingBarController?
    private lazy var selectionAskController = SelectionAskController { [weak self] conversationContext in
        self?.startSelectionAskFollowUp(conversationContext: conversationContext) ?? false
    } onFinishFollowUp: { [weak self] in
        self?.finishSelectionAskFollowUp()
    } onCancelFollowUp: { [weak self] in
        self?.cancelSelectionAskFollowUp()
    }
    private lazy var recordingControlCoordinator = RecordingControlCoordinator(
        followUpController: selectionAskController
    ) { [weak self] action in
        self?.performStandardRecordingAction(action)
    }
    private let hotkeyManager = HotkeyManager()
    private let session = RecognitionSession()
    private var selectionAskFollowUpStartGate = SelectionAskFollowUpStartGate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Type4Me] applicationDidFinishLaunching")
        // Restore system volume if previous session crashed while volume was lowered
        SystemVolumeManager.restoreIfNeeded()
        #if HAS_CLOUD_SUBSCRIPTION
        AppEditionMigration.migrateIfNeeded()
        Task { await RegionDetector.detect() }
        #endif
        // Show or hide Dock icon based on user preference
        let showDock = UserDefaults.standard.object(forKey: "tf_showDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        KeychainService.migrateIfNeeded()
        HotwordStorage.migrateIfNeeded()
        SnippetStorage.migrateIfNeeded()
        AudioInputDevicePreferenceStore.migrateIfNeeded()

        // Sync hotwords to Volcengine cloud table (async, non-blocking)
        VolcHotwordSyncManager.syncIfNeeded()

        // Deploy bundled models (local variant) before anything touches model paths
        ModelManager.deployBundledModelsIfNeeded()

        DebugFileLogger.startSession()
        DebugFileLogger.log("applicationDidFinishLaunching")
        floatingBarController = FloatingBarController(state: appState)
        appState.onRecordingControlAction = { [weak self] action in
            self?.recordingControlCoordinator.perform(action)
        }

        // Bridge ASR events → AppState for floating bar display
        let session = self.session

        // 历史记录字数迁移（用 session 自带的 historyStore，迁移后 UI 能刷新）
        Task { await session.historyStore.migrateCharacterCounts() }
        let appState = self.appState

        SoundFeedback.warmUp()
        AudioInputDeviceMonitor.shared.start()
        AudioKeepAliveManager.syncState()

        // Pre-warm audio subsystem and ASR connection so the first recording starts instantly
        Task { await session.warmUp() }
        session.warmUpASRConnection()

        // Bridge audio level → isolated meter (no SwiftUI observation overhead)
        Task {
            await session.setOnAudioLevel { level in
                appState.audioLevel.current = level
            }
        }

        Task {
            await session.setOnASREvent { event in
                Task { @MainActor in
                    switch event {
                    case .ready:
                        NSLog("[Type4Me] ready event received")
                        DebugFileLogger.log("ready event received, current barPhase=\(String(describing: appState.barPhase))")
                        appState.markRecordingReady()
                        Task { @MainActor in
                            guard appState.barPhase == .recording else {
                                DebugFileLogger.log("playStart aborted, barPhase=\(String(describing: appState.barPhase))")
                                return
                            }
                            NSLog("[Type4Me] playStart firing")
                            DebugFileLogger.log("playStart firing")
                            // BT wake-up preamble is baked into the sound buffer itself.
                            SoundFeedback.playStart()
                            // Lower volume after start sound finishes playing
                            let targetVolumePercent = UserDefaults.standard.integer(forKey: "tf_volumeReduction")
                            if targetVolumePercent >= 0 {
                                let delayMs = SoundFeedback.startSoundDurationMs()
                                if delayMs > 0 {
                                    try? await Task.sleep(for: .milliseconds(delayMs))
                                }
                                guard appState.barPhase == .recording else { return }
                                SystemVolumeManager.lower(to: Float(targetVolumePercent) / 100.0)
                            }
                        }
                    case .transcript(let transcript):
                        appState.setLiveTranscript(transcript)
                    case .completed:
                        self.selectionAskController.recordingDidEnd(.finish)
                        appState.stopRecording()
                        if await session.stoppedByMaxDuration {
                            appState.processingLabelOverride = L("已达最大时长", "Max duration reached")
                        }
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .processingLabelOverride(let label):
                        appState.processingLabelOverride = label
                    case .processingResult(let text):
                        appState.showProcessingResult(text)
                        self.hotkeyManager.isProcessing = true
                    case .recoveryStarted(let text, let message):
                        appState.showRecovery(text: text, message: message)
                        self.hotkeyManager.isProcessing = false
                        self.hotkeyManager.resetActiveState()
                    case .recoveryPrompt(let text, let message):
                        appState.showRecoveryPrompt(text: text, message: message)
                        self.hotkeyManager.isProcessing = false
                        self.hotkeyManager.resetActiveState()
                    case .recoverySucceeded(let text, let message):
                        appState.showRecoveryResult(text: text, message: message)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .recoveryFailed(let text, let message):
                        appState.showRecoveryResult(text: text, message: message)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .recoveryInterrupted(let text, let message):
                        if appState.barPhase == .recovering {
                            appState.showRecoveryResult(text: text, message: message)
                        }
                        self.hotkeyManager.isProcessing = false
                        self.hotkeyManager.resetActiveState()
                    case .finalized(let text, let injection):
                        appState.finalize(text: text, outcome: injection)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .macActionResult(let message, let status):
                        appState.showMacActionResult(message: message, status: status)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .selectionAskStarted(let question, let selectedText):
                        appState.cancel()
                        self.selectionAskController.begin(question: question, selectedText: selectedText)
                        self.hotkeyManager.isProcessing = true
                    case .selectionAskAnswerDelta(let delta):
                        self.selectionAskController.appendAnswerDelta(delta)
                    case .selectionAskAnswerCompleted:
                        self.selectionAskController.completeAnswer()
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    case .error(let error):
                        appState.showError(self.userFacingMessage(for: error))
                        self.selectionAskController.recordingDidEnd(.cancel)
                        self.hotkeyManager.isProcessing = false
                        self.safeResetHotkeyState()
                    }
                }
            }
        }

        // Start periodic update checking
        UpdateChecker.shared.startPeriodicChecking(appState: appState)
        appUpdater.checkPostUpdateStatus()

        // Reconcile current mode against the active provider before hotkeys are registered.
        refreshModeAvailability()

        // Re-register when modes change in Settings
        NotificationCenter.default.addObserver(
            forName: .modesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.refreshModeAvailability()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .asrProviderDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.refreshModeAvailability()
            }
        }

        // Suppress/resume hotkeys during hotkey recording
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingDidStart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.hotkeyManager.isSuppressed = true
            }
        }
        NotificationCenter.default.addObserver(
            forName: .hotkeyRecordingDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.hotkeyManager.isSuppressed = false
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startHotkeyWithRetry()
        }

        // Show setup wizard on first launch
        #if HAS_CLOUD_SUBSCRIPTION
        let needsSetup = !appState.hasCompletedSetup || appState.appEdition == nil
        #else
        let needsSetup = !appState.hasCompletedSetup
        #endif
        if needsSetup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    _ = NSApp.sendAction(Selector(("showSetupWindow:")), to: nil, from: nil)
                }
            }
        }

        // Start SenseVoice Python server if local ASR is selected
        let needsLocalServer = KeychainService.selectedASRProvider == .sherpa
        if needsLocalServer {
            if ModelManager.isQwen3ASRBundled {
                Task {
                    do {
                        try await SenseVoiceServerManager.shared.start()
                    } catch {
                        NSLog("[App] SenseVoice server start failed: %@", String(describing: error))
                    }
                }
            } else if KeychainService.selectedASRProvider == .sherpa {
                // Cloud-only build: local ASR not available, switch to default cloud provider
                NSLog("[App] Local ASR not available (cloud build), switching to volcano")
                KeychainService.selectedASRProvider = .volcano
            }
        }

        // UI iteration can open Settings directly without depending on the menu bar
        // status item's visibility. This launch argument is Debug-only and has no
        // effect on normal or release launches.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            NSApp.setActivationPolicy(.regular)
            presentSettingsWhenReady(remainingAttempts: 20)
        } else {
            checkMenuBarVisibility()
        }
        #else
        // Check if menu bar icon is hidden by macOS 26+ "Allow in Menu Bar" setting
        checkMenuBarVisibility()
        #endif

        // Listen for Dock icon preference changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dockIconPreferenceChanged(_:)),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    private func refreshModeAvailability() {
        let provider = KeychainService.selectedASRProvider
        appState.reconcileCurrentMode(for: provider)
        updateSelectionAskShortcutHint()
        registerHotkeys(for: provider)
    }

    private func updateSelectionAskShortcutHint() {
        let hint = appState.availableModes
            .first(where: { $0.id == ProcessingMode.selectionAskId })?
            .hotkeyBindings
            .map { HotkeyRecorderView.keyDisplayName(keyCode: $0.keyCode, modifiers: $0.modifiers) }
            .joined(separator: " / ") ?? ""
        selectionAskController.updateFollowUpShortcutHint(hint)
    }

    private func registerHotkeys(for provider: ASRProvider) {
        let availableModes = appState.availableModes
        let modes = ASRProviderRegistry.supportedModes(from: availableModes, for: provider)
        let bindings: [ModeBinding] = modes.flatMap { mode -> [ModeBinding] in
            let capturedMode = mode
            let onStart: @Sendable () -> Void = { [weak self] in
                guard let self else { return }

                if capturedMode.executionKind == .selectionAsk,
                   MainActor.assumeIsolated({ self.selectionAskController.isVisible }) {
                    let wasRecording = MainActor.assumeIsolated {
                        self.selectionAskController.isRecordingFollowUp
                    }
                    let handled = MainActor.assumeIsolated {
                        self.selectionAskController.performPrimaryFollowUpAction()
                    }
                    if !handled || wasRecording {
                        MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                    }
                    return
                }

                let phase = MainActor.assumeIsolated { self.appState.barPhase }

                // Safety: if already recording, the toggle state is out of sync.
                // Redirect to stop so we don't discard accumulated text.
                if phase == .recording || phase == .preparing {
                    NSLog("[Type4Me] >>> HOTKEY: toggle desync – onStart while recording, redirecting to STOP (phase=%@)", String(describing: phase))
                    DebugFileLogger.log("hotkey toggle desync: onStart while recording, redirecting to stop phase=\(phase)")
                    MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                    MainActor.assumeIsolated { self.appState.stopRecording() }
                    if phase == .preparing {
                        Task { await self.session.cancelRecording() }
                    } else {
                        Task { await self.session.stopRecording() }
                    }
                    return
                }

                if phase == .recovering {
                    NSLog("[Type4Me] >>> HOTKEY: recovery press")
                    DebugFileLogger.log("hotkey recovery press")
                    MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                    let selectedProvider = KeychainService.selectedASRProvider
                    let resolvedMode = ASRProviderRegistry.resolvedMode(for: capturedMode, provider: selectedProvider)
                    let effectiveMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
                    Task {
                        let action = await self.session.handleRecoveryHotkeyPress()
                        guard action == .interrupted else { return }
                        await MainActor.run {
                            self.appState.currentMode = effectiveMode
                            self.appState.startRecording()
                        }
                        await self.session.startRecording(mode: effectiveMode)
                    }
                    return
                }

                // Block new recording while LLM/injection is still in progress.
                // The current session must finish (paste + history save) before a new one can start.
                if phase == .processing {
                    NSLog("[Type4Me] >>> HOTKEY: onStart blocked – still processing")
                    DebugFileLogger.log("hotkey onStart blocked: still processing")
                    MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                    return
                }

                let selectedProvider = KeychainService.selectedASRProvider
                let resolvedMode = ASRProviderRegistry.resolvedMode(for: capturedMode, provider: selectedProvider)
                let effectiveMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
                NSLog("[Type4Me] >>> HOTKEY: Record START (mode: %@)", effectiveMode.name)
                DebugFileLogger.log("hotkey record start mode=\(effectiveMode.name)")
                Task { @MainActor in
                    self.appState.currentMode = effectiveMode
                    self.appState.startRecording()
                }
                Task {
                    // Wait for previous session to fully clean up before starting
                    let ready = await self.session.awaitIdle()
                    if !ready {
                        NSLog("[Type4Me] >>> HOTKEY: previous session did not reach idle in time")
                        DebugFileLogger.log("hotkey start: awaitIdle timed out")
                    }
                    await self.session.startRecording(mode: effectiveMode)
                }
            }
            let onStop: @Sendable () -> Void = { [weak self] in
                guard let self else { return }

                if capturedMode.executionKind == .selectionAsk,
                   MainActor.assumeIsolated({
                       self.selectionAskController.isVisible
                           && self.selectionAskController.isRecordingFollowUp
                   }) {
                    _ = MainActor.assumeIsolated {
                        self.selectionAskController.handleActiveRecordingAction(.finish)
                    }
                    return
                }

                let phase = MainActor.assumeIsolated { self.appState.barPhase }
                NSLog("[Type4Me] >>> HOTKEY: Record STOP (phase=%@)", String(describing: phase))
                DebugFileLogger.log("hotkey record stop phase=\(phase)")
                if phase == .recovering {
                    MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                    Task { _ = await self.session.handleRecoveryHotkeyPress() }
                    return
                }
                MainActor.assumeIsolated { self.appState.stopRecording() }
                if phase == .preparing {
                    Task { await self.session.cancelRecording() }
                } else {
                    Task { await self.session.stopRecording() }
                }
            }

            // Fan out: one ModeBinding per hotkey binding, all sharing this mode's callbacks.
            return mode.hotkeyBindings.map { hk in
                ModeBinding(
                    bindingId: hk.id,
                    modeId: mode.id,
                    keyCode: CGKeyCode(hk.keyCode),
                    modifiers: CGEventFlags(rawValue: hk.modifiers ?? 0),
                    style: hk.style,
                    onStart: onStart,
                    onStop: onStop
                )
            }
        }
        hotkeyManager.registerBindings(bindings)

        // Cross-mode finish: user pressed mode B's key while mode A was recording.
        // The preference decides whether mode A or mode B processes the recording.
        hotkeyManager.onCrossModeFinish = { [weak self] newModeId in
            guard let self else { return }
            guard let newMode = availableModes.first(where: { $0.id == newModeId }) else { return }
            let phase = MainActor.assumeIsolated { self.appState.barPhase }
            if phase == .recovering {
                MainActor.assumeIsolated { self.hotkeyManager.resetActiveState() }
                Task { _ = await self.session.handleRecoveryHotkeyPress() }
                return
            }
            let startingMode = MainActor.assumeIsolated { self.appState.currentMode }
            let allowsModeSwitch = CrossModeFinishPreference.isEnabled()
            let endingMode: ProcessingMode
            if allowsModeSwitch {
                let selectedProvider = KeychainService.selectedASRProvider
                let resolvedMode = ASRProviderRegistry.resolvedMode(for: newMode, provider: selectedProvider)
                endingMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode
            } else {
                // Avoid provider resolution entirely when the starting mode must be retained.
                endingMode = newMode
            }
            let processingMode = CrossModeFinishPreference.processingMode(
                startingMode: startingMode,
                endingMode: endingMode,
                isEnabled: allowsModeSwitch
            )
            NSLog(
                "[Type4Me] >>> HOTKEY: Cross-mode finish (start=%@, end=%@, process=%@)",
                startingMode.name,
                newMode.name,
                processingMode.name
            )
            DebugFileLogger.log(
                "hotkey cross-mode finish start=\(startingMode.name) end=\(newMode.name) process=\(processingMode.name)"
            )
            MainActor.assumeIsolated {
                if allowsModeSwitch {
                    self.appState.currentMode = processingMode
                }
                self.appState.stopRecording()
            }
            Task {
                if allowsModeSwitch {
                    await self.session.switchMode(to: processingMode)
                }
                await self.session.stopRecording()
            }
        }

        // ESC abort: skip injection but let recognition/clipboard/history proceed.
        // Returns true if the abort was actually handled (ESC should be swallowed).
        hotkeyManager.onESCAbort = { [weak self] in
            guard let self else { return false }
            if MainActor.assumeIsolated({
                self.selectionAskController.isVisible
                    && self.selectionAskController.isRecordingFollowUp
            }) {
                return MainActor.assumeIsolated {
                    self.selectionAskController.handleActiveRecordingAction(.cancel)
                }
            }
            let phase = appState.barPhase
            guard phase == .recording || phase == .processing || phase == .preparing else {
                return false  // Not in an active session, let ESC pass through
            }
            NSLog("[Type4Me] >>> HOTKEY: ESC abort injection (phase=%@)", String(describing: phase))
            DebugFileLogger.log("hotkey ESC abort injection phase=\(phase)")
            MainActor.assumeIsolated { self.appState.stopRecording() }
            if phase == .preparing {
                Task { await self.session.cancelRecording() }
            } else {
                Task {
                    await self.session.abortInjection()
                    await self.session.stopRecording()
                }
            }
            return true
        }

        // Sync ESC abort enabled setting to HotkeyManager
        syncESCAbortSetting()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { [weak self] in
                self?.syncESCAbortSetting()
            }
        }
    }

    private func startSelectionAskFollowUp(conversationContext: String) -> Bool {
        let phase = appState.barPhase
        guard phase != .processing else {
            DebugFileLogger.log("selectionAsk follow-up blocked: still processing")
            return false
        }
        guard phase != .recording, phase != .preparing else {
            DebugFileLogger.log("selectionAsk follow-up blocked: another recording is active")
            return false
        }

        let selectedProvider = KeychainService.selectedASRProvider
        let availableModes = appState.availableModes
        let resolvedMode = ASRProviderRegistry.resolvedMode(for: .selectionAsk, provider: selectedProvider)
        let effectiveMode = availableModes.first(where: { $0.id == resolvedMode.id }) ?? resolvedMode

        DebugFileLogger.log("selectionAsk follow-up start")
        let generation = selectionAskFollowUpStartGate.begin()
        appState.currentMode = effectiveMode
        appState.startRecording()
        Task {
            let ready = await self.session.awaitIdle()
            if !ready {
                DebugFileLogger.log("selectionAsk follow-up start: awaitIdle timed out")
            }
            let shouldStart = await MainActor.run {
                self.selectionAskFollowUpStartGate.allowsStart(
                    token: generation,
                    isFollowUpActive: self.selectionAskController.isRecordingFollowUp,
                    phase: self.appState.barPhase
                )
            }
            guard shouldStart else {
                DebugFileLogger.log("selectionAsk follow-up start: cancelled before session start")
                return
            }
            await self.session.setSelectionAskConversationContext(conversationContext)
            await self.session.startRecording(mode: effectiveMode)
        }
        return true
    }

    private func finishSelectionAskFollowUp() {
        let phase = appState.barPhase
        DebugFileLogger.log("selectionAsk follow-up finish phase=\(phase)")
        selectionAskFollowUpStartGate.invalidate()
        hotkeyManager.resetActiveState()

        switch phase {
        case .recording:
            appState.stopRecording()
            Task { await self.session.stopRecording() }
        case .preparing:
            // No ASR session is ready to finalize yet, so there is no usable
            // question to process. Tear down the pending start deterministically.
            appState.cancel()
            Task { await self.session.cancelRecording() }
        case .processing, .recovering, .done, .error, .hidden:
            break
        }
    }

    private func cancelSelectionAskFollowUp() {
        let phase = appState.barPhase
        DebugFileLogger.log("selectionAsk follow-up cancel phase=\(phase)")
        selectionAskFollowUpStartGate.invalidate()
        appState.cancel()
        hotkeyManager.resetActiveState()
        Task { await self.session.cancelRecording() }
    }

    private func performStandardRecordingAction(_ action: RecordingControlAction) {
        let phase = appState.barPhase
        guard phase == .preparing || phase == .recording else { return }

        DebugFileLogger.log("floating indicator: \(action) recording phase=\(phase)")
        hotkeyManager.resetActiveState()

        switch action {
        case .finish:
            appState.stopRecording()
            if phase == .preparing {
                Task { await session.cancelRecording() }
            } else {
                Task { await session.stopRecording() }
            }
        case .cancel:
            appState.stopRecording()
            if phase == .preparing {
                Task { await session.cancelRecording() }
            } else {
                Task {
                    await session.abortInjection()
                    await session.stopRecording()
                }
            }
        }
    }

    private func syncESCAbortSetting() {
        hotkeyManager.isESCAbortEnabled = true
    }

    private var retryTimer: Timer?
    private var hotkeyRetryCount = 0

    private func startHotkeyWithRetry() {
        let success = hotkeyManager.start()
        NSLog("[Type4Me] Hotkey setup: %@", success ? "OK" : "FAILED (need Accessibility permission)")

        if success {
            retryTimer?.invalidate()
            retryTimer = nil
            hotkeyRetryCount = 0
            return
        }

        // Surface the unified permission guide. Skip on first launch when
        // the setup wizard will walk the user through permissions inline —
        // otherwise we'd stack the guide on top of the wizard.
        let showWizard: Bool = {
            #if HAS_CLOUD_SUBSCRIPTION
            return !appState.hasCompletedSetup || appState.appEdition == nil
            #else
            return !appState.hasCompletedSetup
            #endif
        }()
        if !showWizard {
            presentPermissionGuide()
        }

        hotkeyRetryCount = 0
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(
            timeInterval: 2.0,
            target: self,
            selector: #selector(handleHotkeyRetry(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc
    private func handleHotkeyRetry(_ timer: Timer) {
        if PermissionManager.hasAccessibilityPermission {
            let ok = hotkeyManager.start()
            hotkeyRetryCount += 1
            NSLog("[Type4Me] Hotkey retry #%d: %@", hotkeyRetryCount, ok ? "OK" : "still failing")
            if ok {
                timer.invalidate()
                retryTimer = nil
                hotkeyRetryCount = 0
            } else if hotkeyRetryCount >= 5 {
                // Permission granted but event tap still fails (macOS caches denial at kernel level).
                // Suggest restart.
                timer.invalidate()
                retryTimer = nil
                hotkeyRetryCount = 0
                NSLog("[Type4Me] Accessibility granted but hotkey tap failed after retries. Suggesting restart.")
                showRestartAlert()
            }
        }
    }

    private func showRestartAlert() {
        let alert = NSAlert()
        alert.messageText = L("辅助功能权限已开启，但快捷键未生效", "Accessibility is enabled, but the hotkey is not working")
        alert.informativeText = L(
            "macOS 有时需要重启应用才能激活全局快捷键。点击「重启」自动重启 Type4Me。",
            "macOS sometimes requires an app restart before global hotkeys take effect. Click Restart to relaunch Type4Me."
        )
        alert.addButton(withTitle: L("重启", "Restart"))
        alert.addButton(withTitle: L("稍后", "Later"))
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn {
            // Relaunch the app
            let url = Bundle.main.bundleURL
            let task = Process()
            task.launchPath = "/usr/bin/open"
            task.arguments = ["-n", url.path]
            try? task.run()
            NSApp.terminate(nil)
        }
    }

    @objc
    private func dockIconPreferenceChanged(_ notification: Notification) {
        // `UserDefaults.didChangeNotification` is delivered on whatever thread
        // performed the change. When another process (e.g. System Settings /
        // tccd while the user grants a permission) triggers a cross-process
        // preferences sync, this fires on a background thread. Touching NSApp
        // off the main thread is unsafe and crashes the app, so always hop to
        // main before reading/mutating the activation policy.
        if Thread.isMainThread {
            Self.applyDockIconPreference()
        } else {
            DispatchQueue.main.async { Self.applyDockIconPreference() }
        }
    }

    private static func applyDockIconPreference() {
        let showDock = UserDefaults.standard.object(forKey: "tf_showDockIcon") as? Bool ?? true
        let current = NSApp.activationPolicy()
        let desired: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        if current != desired {
            NSApp.setActivationPolicy(desired)
        }
    }

    // MARK: - Menu Bar Visibility Check (macOS 26+)

    /// On macOS 26 Tahoe, System Settings > Menu Bar > "Allow in Menu Bar" can hide
    /// third-party status items by rendering them offscreen. Detect this and alert the user.
    private func checkMenuBarVisibility() {
        // Only check on macOS 26+ where this feature exists
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return }

        // Delay to give SwiftUI MenuBarExtra time to create the status item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.performMenuBarCheck()
            }
        }
    }

    private func performMenuBarCheck() {
        // Find status bar windows belonging to our app.
        // SwiftUI's MenuBarExtra creates an NSStatusBarWindow with a button inside.
        let statusBarWindows = NSApp.windows.filter {
            $0.className.contains("NSStatusBar")
        }

        let isVisible: Bool
        if statusBarWindows.isEmpty {
            // No status bar window at all — icon wasn't created
            isVisible = false
        } else {
            // Check if any status bar window is in a reasonable screen position.
            // macOS 26 moves hidden items far offscreen (e.g. y < -10000).
            // Check against ALL screens to handle multi-monitor setups correctly.
            let allScreens = NSScreen.screens
            isVisible = statusBarWindows.contains { window in
                let frame = window.frame
                return allScreens.contains { screen in
                    let sf = screen.frame
                    return frame.origin.x >= sf.minX - 100
                        && frame.origin.x <= sf.maxX + 100
                        && frame.origin.y >= sf.minY - 100
                }
            }
        }

        guard !isVisible else { return }

        NSLog("[Type4Me] Menu bar icon appears hidden by system settings")

        let alert = NSAlert()
        alert.messageText = L(
            "菜单栏图标被隐藏",
            "Menu Bar Icon Hidden"
        )
        alert.informativeText = L(
            "macOS 的菜单栏设置可能隐藏了 Type4Me 图标。\n\n请前往 系统设置 > 菜单栏，在「允许在菜单栏中显示」列表中开启 Type4Me。",
            "macOS may have hidden the Type4Me icon.\n\nGo to System Settings > Menu Bar and enable Type4Me in the 'Allow in Menu Bar' list."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("打开系统设置", "Open System Settings"))
        alert.addButton(withTitle: L("稍后处理", "Later"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Open Menu Bar settings (macOS 26+)
            if let url = URL(string: "x-apple.systempreferences:com.apple.MenuBar-Settings") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Stored by MenuBarContent so AppDelegate can open the settings window.
    static var openSettingsAction: (() -> Void)?

    /// Stored by MenuBarContent so AppDelegate can open the unified
    /// permission guide window from anywhere (startup, hotkey failure path,
    /// etc.). If the action isn't wired yet (e.g. very early in launch
    /// before the first MenuBarExtra render), calls are retried on the next
    /// runloop.
    static var openPermissionGuideAction: (() -> Void)?

    /// Present the permission guide window, activating the app and retrying
    /// until the SwiftUI scene registers its open action.
    func presentPermissionGuide() {
        if let action = Self.openPermissionGuideAction {
            action()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.presentPermissionGuide()
        }
    }

    /// Present the settings window from anywhere (URL command, Dock reopen,
    /// etc.). Uses the standard SwiftUI settings-open selector so it works
    /// even before the MenuBarExtra scene has registered `openSettingsAction`,
    /// and retries on the next runloop until a window is visible.
    func presentSettings(remainingAttempts: Int = 25) {
        let hasVisibleAppWindow = NSApp.windows.contains {
            $0.isVisible && !$0.className.contains("NSStatusBar")
        }
        if hasVisibleAppWindow {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        Self.openSettingsAction?()
        NSApp.activate(ignoringOtherApps: true)
        guard remainingAttempts > 1 else {
            NSLog("[Type4Me] Timed out while opening Settings")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.presentSettings(remainingAttempts: remainingAttempts - 1)
        }
    }

    #if DEBUG
    private func presentSettingsWhenReady(remainingAttempts: Int) {
        let hasVisibleAppWindow = NSApp.windows.contains {
            $0.isVisible && !$0.className.contains("NSStatusBar")
        }
        if hasVisibleAppWindow {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if let action = Self.openSettingsAction {
            action()
        }
        guard remainingAttempts > 1 else {
            NSLog("[Type4Me] Timed out while opening Settings for UI preview")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.presentSettingsWhenReady(remainingAttempts: remainingAttempts - 1)
        }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        SystemVolumeManager.restore()
        // Synchronous kill: don't rely on async Task, app exits immediately after this returns
        SenseVoiceServerManager.killAllServerProcesses()
    }

    // MARK: - URL Scheme Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "type4me" else { continue }
            switch url.host {
            case "reload-vocabulary":
                NSLog("[Type4Me] URL command: reload-vocabulary")
                SnippetStorage.invalidateCache()
                HotwordStorage.invalidateCache()
                NotificationCenter.default.post(name: SnippetStorage.didChangeNotification, object: nil)
                NotificationCenter.default.post(name: HotwordStorage.didChangeNotification, object: nil)
                SenseVoiceServerManager.syncHotwordsAndRestart()
            case "auth":
                NSLog("[Type4Me] URL command: auth (no-op, code-based auth now)")
            case "settings", "preferences":
                NSLog("[Type4Me] URL command: settings")
                presentSettings()
            default:
                NSLog("[Type4Me] Unknown URL command: \(url)")
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Self.openSettingsAction?()
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Only reset hotkey state when no new recording is in progress.
    /// Prevents a stale finalized/completed event from corrupting the toggle
    /// state of a recording that started after the event was emitted.
    private func safeResetHotkeyState() {
        let phase = appState.barPhase
        if phase == .recording || phase == .preparing {
            DebugFileLogger.log("safeResetHotkeyState: skipped (barPhase=\(phase))")
            return
        }
        hotkeyManager.resetActiveState()
    }

    private func userFacingMessage(for error: Error) -> String {
        if let captureError = error as? AudioCaptureError,
           let description = captureError.errorDescription {
            return description
        }

        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        let nsError = error as NSError
        if let description = nsError.userInfo[NSLocalizedDescriptionKey] as? String,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        return L("录音启动失败", "Failed to start recording")
    }
}

// MARK: - Menu Bar Content

struct MenuBarContent: View {

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openWindow) private var openSettingsWindow
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }

        Divider()

        // Mode hotkey hints (click to open settings)
        ForEach(appState.availableModes) { mode in
            Button {
                openSettingsWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: .navigateToMode, object: mode.id
                )
            } label: {
                let hotkeyText = mode.hotkeyBindings.isEmpty
                    ? L("未绑定", "Unbound")
                    : mode.hotkeyBindings
                        .map { HotkeyRecorderView.keyDisplayName(keyCode: $0.keyCode, modifiers: $0.modifiers) }
                        .joined(separator: " / ")
                Text("\(mode.name)  [\(hotkeyText)]")
            }
        }

        Divider()

        Button(L("历史记录...", "History...")) {
            openSettingsWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .navigateToHistory, object: nil)
        }

        Button(L("偏好设置...", "Preferences...")) {
            openSettingsWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button(L("退出 Type4Me", "Quit Type4Me")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)

        // Force re-render when language changes
        let _ = language

        // Register the settings opener for Dock icon click
        let _ = {
            AppDelegate.openSettingsAction = { [openSettingsWindow] in
                openSettingsWindow(id: "settings")
            }
            AppDelegate.openPermissionGuideAction = { [openSettingsWindow] in
                openSettingsWindow(id: "permission-guide")
            }
        }()
    }

    private var statusColor: Color {
        switch appState.barPhase {
        case .preparing: return TF.recording
        case .recording: return TF.recording
        case .processing: return TF.amber
        case .recovering: return TF.amber
        case .done: return TF.success
        case .error: return TF.settingsAccentRed
        case .hidden: return .secondary.opacity(0.4)
        }
    }

    private var statusText: String {
        switch appState.barPhase {
        case .preparing: return L("录制中", "Recording")
        case .recording: return L("录制中", "Recording")
        case .processing: return appState.effectiveProcessingLabel
        case .recovering: return appState.effectiveProcessingLabel
        case .done: return L("完成", "Done")
        case .error: return L("错误", "Error")
        case .hidden: return L("就绪", "Ready")
        }
    }
}
