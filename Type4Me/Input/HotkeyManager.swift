import Cocoa
import MediaPlayer

typealias HotkeyStyle = ProcessingMode.HotkeyStyle

struct ModeBinding {
    let bindingId: UUID
    let modeId: UUID
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags  // .maskCommand etc. Use [] for no modifiers
    let style: HotkeyStyle
    let onStart: @Sendable () -> Void
    let onStop: @Sendable () -> Void

    /// Whether this binding is for a mouse button (encoded with high-bit keyCode).
    var isMouseButton: Bool { ModeBinding.isMouseKeyCode(Int(keyCode)) }

    /// Whether this binding is for a media key (encoded with high-bit keyCode).
    var isMediaKey: Bool { ModeBinding.isMediaKeyCode(Int(keyCode)) }

    /// The mouse button number (2=middle, 3+=side buttons). Only valid when isMouseButton is true.
    var mouseButtonNumber: Int { ModeBinding.mouseButtonNumber(from: Int(keyCode)) }

    // MARK: - Mouse Button Encoding
    //
    // Convention: keyCode = 0x8000 + buttonNumber.
    // Middle button (2) → 0x8002, Side button 3 → 0x8003, etc.
    // Keyboard keyCodes are 0–127, so no collision.
    // The encoded value fits in both Int and UInt16 (CGKeyCode).

    private static let mouseKeyCodeBase = 0x8000
    private static let mediaKeyCodeBase = 0x9000
    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    static let functionKeyCodes: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    static let standardModifierMask: CGEventFlags = [
        .maskCommand,
        .maskShift,
        .maskAlternate,
        .maskControl,
        .maskSecondaryFn,
    ]

    /// Encode a mouse button number as a keyCode (for storage in a HotkeyBinding).
    static func mouseKeyCode(for buttonNumber: Int) -> Int { mouseKeyCodeBase + buttonNumber }

    /// Decode a mouse keyCode back to a button number.
    static func mouseButtonNumber(from keyCode: Int) -> Int { keyCode - mouseKeyCodeBase }

    /// Check if a keyCode represents a mouse button.
    static func isMouseKeyCode(_ keyCode: Int) -> Bool { keyCode >= mouseKeyCodeBase && keyCode < mediaKeyCodeBase }

    // MARK: - Media Key Encoding
    //
    // Convention: keyCode = 0x9000 + NX_KEYTYPE value.
    // NX_KEYTYPE_SOUND_UP=0, NX_KEYTYPE_SOUND_DOWN=1, NX_KEYTYPE_MUTE=7,
    // NX_KEYTYPE_PLAY=16, NX_KEYTYPE_NEXT=17, NX_KEYTYPE_PREVIOUS=18,
    // NX_KEYTYPE_FAST=19, NX_KEYTYPE_REWIND=20.
    // No collision with keyboard (0–127) or mouse (0x8000+) keyCodes.

    /// Encode an NX_KEYTYPE value as a keyCode (for storage in a HotkeyBinding).
    static func mediaKeyCode(for keyType: Int) -> Int { mediaKeyCodeBase + keyType }

    /// Decode a media keyCode back to the NX_KEYTYPE value.
    static func mediaKeyType(from keyCode: Int) -> Int { keyCode - mediaKeyCodeBase }

    /// Check if a keyCode represents a media key.
    static func isMediaKeyCode(_ keyCode: Int) -> Bool { keyCode >= mediaKeyCodeBase }

    static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    static func isFunctionKeyCode(_ keyCode: Int) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    static func modifierEventFlag(for keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    static func normalizedModifierFlags(_ flags: CGEventFlags, forKeyCode keyCode: Int? = nil) -> CGEventFlags {
        var normalized = flags.intersection(standardModifierMask)
        // macOS reports the Fn/function modifier on F-key events themselves.
        // Treat that as part of the F-key, not as an extra hotkey modifier.
        if let keyCode, isFunctionKeyCode(keyCode) {
            normalized.remove(.maskSecondaryFn)
        }
        return normalized
    }

    static func hotkeysAreEquivalent(
        keyCode: Int,
        modifiers: UInt64?,
        otherKeyCode: Int,
        otherModifiers: UInt64?
    ) -> Bool {
        guard keyCode == otherKeyCode else { return false }
        if isMouseKeyCode(keyCode) || isMediaKeyCode(keyCode) {
            return true
        }
        let flags = normalizedModifierFlags(CGEventFlags(rawValue: modifiers ?? 0), forKeyCode: keyCode)
        let otherFlags = normalizedModifierFlags(CGEventFlags(rawValue: otherModifiers ?? 0), forKeyCode: otherKeyCode)
        return flags == otherFlags
    }

    static func fullModifierFlags(keyCode: Int, modifiers: UInt64?) -> CGEventFlags? {
        guard let ownFlag = modifierEventFlag(for: keyCode) else { return nil }
        var flags = normalizedModifierFlags(CGEventFlags(rawValue: modifiers ?? 0))
        flags.insert(ownFlag)
        return flags
    }

    static func modifierBindingIsPrefix(
        modifierKeyCode: Int,
        modifierModifiers: UInt64?,
        otherKeyCode: Int,
        otherModifiers: UInt64?
    ) -> Bool {
        guard let flags = fullModifierFlags(keyCode: modifierKeyCode, modifiers: modifierModifiers) else {
            return false
        }

        if let otherFlags = fullModifierFlags(keyCode: otherKeyCode, modifiers: otherModifiers) {
            return flags != otherFlags && flags.isSubset(of: otherFlags)
        }

        guard let regularFlags = regularKeyModifierFlags(keyCode: otherKeyCode, modifiers: otherModifiers) else {
            return false
        }
        return flags.isSubset(of: regularFlags)
    }

    static func hasModifierPrefixConflict(
        keyCode: Int,
        modifiers: UInt64?,
        otherKeyCode: Int,
        otherModifiers: UInt64?
    ) -> Bool {
        modifierBindingIsPrefix(
            modifierKeyCode: keyCode,
            modifierModifiers: modifiers,
            otherKeyCode: otherKeyCode,
            otherModifiers: otherModifiers
        ) || modifierBindingIsPrefix(
            modifierKeyCode: otherKeyCode,
            modifierModifiers: otherModifiers,
            otherKeyCode: keyCode,
            otherModifiers: modifiers
        )
    }

    private static func regularKeyModifierFlags(keyCode: Int, modifiers: UInt64?) -> CGEventFlags? {
        guard !isMouseKeyCode(keyCode),
              !isMediaKeyCode(keyCode),
              !isModifierKeyCode(keyCode)
        else { return nil }
        let flags = normalizedModifierFlags(CGEventFlags(rawValue: modifiers ?? 0), forKeyCode: keyCode)
        return flags.isEmpty ? nil : flags
    }
}

final class HotkeyManager: NSObject {

    // MARK: - Configuration

    private var bindings: [ModeBinding] = []
    /// Per-binding state, all keyed by `HotkeyBinding.id` so multiple bindings of the
    /// same mode never collide.
    private var holdState: [UUID: Bool] = [:]
    private var wasModifierDown: [UUID: Bool] = [:]
    private var holdSafetyTimers: [UUID: Timer] = [:]
    /// The single binding currently driving a recording (hold or toggle), if any.
    /// Only one recording can be active at a time across all modes/bindings.
    private var activeRecordingBindingId: UUID?
    /// The mode owning the active recording binding. Used to distinguish same-mode
    /// (stop) from cross-mode (switch) presses.
    private var activeRecordingModeId: UUID?
    private struct PendingModifierTrigger {
        let binding: ModeBinding
        let token: UUID
    }
    private var pendingModifierTriggers: [UUID: PendingModifierTrigger] = [:]
    /// The modifier-only binding whose full flag combo is currently exactly held.
    /// Modifier combos are matched by their complete set of flags (order-independent),
    /// so we track the single exactly-active combo rather than per-key edge state.
    private var activeModifierComboBindingId: UUID?
    /// Normalized modifier flags observed on the previous flagsChanged event, used to
    /// distinguish building a combo up (a real press) from releasing a larger combo
    /// down through a smaller one (a transient we must not treat as a press).
    private var previousModifierFlags: CGEventFlags = []

    /// Maximum hold duration before auto-stop (seconds).
    private let maxHoldDuration: TimeInterval = 120

    /// Default delay before a *prefix* modifier combo fires (e.g. `fn` when `fn+Shift`
    /// also exists), giving the user time to complete the longer combo.
    static let defaultModifierPrefixTriggerDelay: TimeInterval = 0.25
    /// UserDefaults key to override `defaultModifierPrefixTriggerDelay` at runtime.
    /// No settings UI yet — adjust via `defaults write` if needed.
    static let modifierPrefixTriggerDelayKey = "tf_modifierPrefixTriggerDelay"
    /// Effective prefix-combo trigger delay (seconds). Reads the UserDefaults override
    /// when a positive value is present, otherwise the default.
    private var modifierPrefixTriggerDelay: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: Self.modifierPrefixTriggerDelayKey)
        return stored > 0 ? stored : Self.defaultModifierPrefixTriggerDelay
    }

    // MARK: - State

    /// When true, all hotkey events pass through unhandled (used during hotkey recording).
    var isSuppressed = false

    /// When true, ESC key aborts active recording.
    var isESCAbortEnabled = true

    /// When true, LLM post-processing is in progress (ESC can also abort this).
    var isProcessing = false

    /// Reset all active recording/hold state. Called when session ends (completed/error/finalized)
    /// to ensure hotkeys and ESC don't remain stuck.
    func resetActiveState() {
        clearActiveRecordingState()
        for key in wasModifierDown.keys { wasModifierDown[key] = false }
        for key in holdState.keys { holdState[key] = false }
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelPendingModifierTriggers()
        activeModifierComboBindingId = nil
        previousModifierFlags = []
    }

    /// Called when recording is finished by a different mode's hotkey.
    /// The application decides whether the ending mode should replace the starting mode.
    var onCrossModeFinish: ((UUID) -> Void)?

    /// Called when ESC is pressed during active recording or processing (abort).
    /// Called when ESC is pressed during active recording or processing (abort).
    /// Returns true if the abort was handled (ESC should be swallowed),
    /// false if the app is not actually in an active session (ESC should pass through).
    var onESCAbort: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    /// Timestamp of the last event received by the tap callback.
    fileprivate var lastEventTime: Date?

    /// Tokens for MPRemoteCommandCenter handlers (prevents Apple Music from auto-launching).
    private var mediaCommandTokens: [(command: MPRemoteCommand, token: Any)] = []
    private var isMediaSessionActive = false

    // MARK: - Registration

    func registerBindings(_ newBindings: [ModeBinding]) {
        bindings = newBindings
        holdState = [:]
        wasModifierDown = [:]
        clearActiveRecordingState()
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelPendingModifierTriggers()
        activeModifierComboBindingId = nil
        previousModifierFlags = []
        updateMediaKeySession()
    }

    // MARK: - Start / Stop

    @discardableResult
    func start() -> Bool {
        let hasMediaKeyBindings = bindings.contains { $0.isMediaKey }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (hasMediaKeyBindings ? (1 << 14) : 0)  // kCGEventSystemDefined (NX_SYSDEFINED) for media/headphone keys

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let tap: CFMachPort?
        if hasMediaKeyBindings {
            // Try cghidEventTap first for more reliable interception of media/headphone keys.
            // If unavailable (e.g. insufficient permissions), fall back to cgSessionEventTap.
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: userInfo
            ) ?? CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        } else {
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        }

        guard let tap = tap else {
            return false
        }

        eventTap = tap
        lastEventTime = nil

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        startHealthCheck()
        updateMediaKeySession()
        return true
    }

    func stop() {
        deactivateMediaKeySession()
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        lastEventTime = nil
        holdState = [:]
        wasModifierDown = [:]
        clearActiveRecordingState()
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelPendingModifierTriggers()
    }

    // MARK: - Health check

    /// Periodically verify the event tap is actually alive.
    /// Detects the "silent disable" race where tapCreate succeeds but the tap is dead.
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }

            // Check 1: Is the tap port still valid? Only recreate the tap for real invalidation,
            // not for normal idle periods with no keyboard/mouse input.
            if !CFMachPortIsValid(tap) {
                NSLog("[Type4Me] Health check: tap port invalid, reinstalling tap...")
                self.reinstallTap()
                return
            }

            // Check 2: Is the tap still enabled at the Mach port level?
            if !CGEvent.tapIsEnabled(tap: tap) {
                NSLog("[Type4Me] Health check: tap disabled, re-enabling...")
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    NSLog("[Type4Me] Health check: tap re-enable failed, reinstalling tap...")
                    self.reinstallTap()
                }
            }
        }
    }

    /// Tear down and recreate the event tap from scratch.
    private func reinstallTap() {
        stop()
        let ok = start()
        NSLog("[Type4Me] Tap reinstall: %@", ok ? "OK" : "FAILED")
    }

    // MARK: - Event handling

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lastEventTime = Date()

        // Re-enable tap if system disabled it, and recover any stuck hold states.
        // When macOS disables the tap (main thread blocked >1s), keyUp events are lost.
        // We must check if held keys are still physically down; if not, fire onStop.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            recoverStuckHolds()
            return Unmanaged.passUnretained(event)
        }

        // Pass all events through when suppressed (hotkey recording in progress)
        if isSuppressed {
            return Unmanaged.passUnretained(event)
        }

        // MARK: Mouse button events (otherMouseDown/Up = middle + side buttons)
        if type == .otherMouseDown || type == .otherMouseUp {
            let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))

            for binding in bindings {
                guard binding.isMouseButton, binding.mouseButtonNumber == buttonNumber else { continue }

                switch binding.style {
                case .hold:
                    if type == .otherMouseDown {
                        handleBindingEvent(binding: binding, pressed: true)
                    } else {
                        handleBindingEvent(binding: binding, pressed: false)
                    }
                case .toggle:
                    if type == .otherMouseDown {
                        handleTogglePress(binding: binding)
                    }
                }
                return nil  // Swallow matched mouse button events
            }

            return Unmanaged.passUnretained(event)
        }

        // MARK: Media key events (headphone buttons, keyboard media keys)
        if type.rawValue == 14 {  // kCGEventSystemDefined (NX_SYSDEFINED)
            guard let nsEvent = NSEvent(cgEvent: event),
                  nsEvent.type == .systemDefined,
                  nsEvent.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }

            let keyType = Int((nsEvent.data1 >> 16) & 0xFFFF)
            let keyState = Int((nsEvent.data1 >> 8) & 0xFF)
            let isKeyDown = keyState == 0x0A
            let isKeyUp = keyState == 0x0B

            guard Self.isKnownMediaKeyType(keyType) else {
                return Unmanaged.passUnretained(event)
            }

            let encodedKeyCode = ModeBinding.mediaKeyCode(for: keyType)

            for binding in bindings {
                guard binding.isMediaKey, Int(binding.keyCode) == encodedKeyCode else { continue }

                switch binding.style {
                case .hold:
                    if isKeyDown {
                        handleBindingEvent(binding: binding, pressed: true)
                    } else if isKeyUp {
                        handleBindingEvent(binding: binding, pressed: false)
                    }
                case .toggle:
                    if isKeyDown {
                        handleTogglePress(binding: binding)
                    }
                }
                return nil  // Swallow matched media key events
            }

            return Unmanaged.passUnretained(event)
        }

        // MARK: Keyboard events
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown {
            cancelPendingModifierTriggers()
        }

        // Modifier-only combos (fn, Ctrl+Shift, fn+Shift, …) are matched by their full
        // set of held flags, independent of the physical order the keys were pressed.
        // Handle them all in one place on every flagsChanged event. When the current
        // flags exactly match a registered combo, swallow the event so the modifier
        // doesn't also trigger its own system behavior.
        if type == .flagsChanged {
            let matchedCombo = evaluateModifierBindings(currentFlags: event.flags)
            return matchedCombo ? nil : Unmanaged.passUnretained(event)
        }

        for binding in bindings {
            // Skip mouse button and media key bindings in the keyboard path
            guard !binding.isMouseButton && !binding.isMediaKey else { continue }
            // Modifier-only bindings are handled by evaluateModifierBindings above.
            guard !isModifierKeyCode(binding.keyCode) else { continue }
            guard binding.keyCode == keyCode else { continue }

            // Regular keys: check modifier flags match
            let requiredMods = normalizedModifierFlags(binding.modifiers, forKeyCode: Int(binding.keyCode))
            let currentMods = normalizedModifierFlags(event.flags, forKeyCode: Int(keyCode))
            guard currentMods == requiredMods else { continue }

            switch binding.style {
            case .hold:
                if type == .keyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                    if isRepeat != 0 { return nil }
                    handleBindingEvent(binding: binding, pressed: true)
                } else if type == .keyUp {
                    handleBindingEvent(binding: binding, pressed: false)
                }
            case .toggle:
                if type == .keyDown {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                    if isRepeat != 0 { return nil }
                    handleTogglePress(binding: binding)
                }
            }
            return nil  // Swallow matched regular key events
        }

        // ESC key (keyCode 53) - abort active recording or processing
        if isESCAbortEnabled && type == .keyDown && keyCode == 53 {
            let isRecording = activeRecordingBindingId != nil || holdState.values.contains(true)
            let shouldAbort = isRecording || isProcessing
            if shouldAbort {
                NSLog("[HotkeyManager] ESC pressed, triggering abort (recording=%@, processing=%@)",
                      isRecording ? "true" : "false", isProcessing ? "true" : "false")
                if onESCAbort?() == true {
                    return nil  // Swallow ESC: abort was handled
                }
                // App is not actually in an active session — stale state.
                // Clean up and let ESC pass through to the system.
                NSLog("[HotkeyManager] ESC abort not handled, resetting stale state")
                isProcessing = false
                resetActiveState()
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Binding dispatch

    /// Unified per-binding event handler.
    /// - Hold bindings: press/release drive start/stop.
    /// - Toggle bindings: only the pressed edge is actionable; modifier toggles arrive as
    ///   level-triggered `flagsChanged`, so they're edge-gated via `wasModifierDown`.
    private func handleBindingEvent(binding: ModeBinding, pressed: Bool) {
        switch binding.style {
        case .hold:
            if pressed {
                handleHoldPress(binding: binding)
            } else {
                handleHoldRelease(binding: binding)
            }

        case .toggle:
            let bindingId = binding.bindingId
            if pressed {
                let wasDown = wasModifierDown[bindingId] ?? false
                guard !wasDown else { return }
                wasModifierDown[bindingId] = true
                handleTogglePress(binding: binding)
            } else {
                wasModifierDown[bindingId] = false
            }
        }
    }

    /// A toggle binding was pressed. Start when idle, stop when the same mode is recording,
    /// or hand off to cross-mode switching when a different mode is recording.
    private func handleTogglePress(binding: ModeBinding) {
        if activeRecordingBindingId != nil {
            if activeRecordingModeId == binding.modeId {
                // Same mode (same binding = toggle off, or a sibling binding): stop.
                stopActiveRecording()
            } else {
                // Different mode: finish the current recording through the app's policy.
                clearActiveRecordingState()
                onCrossModeFinish?(binding.modeId)
            }
        } else {
            startRecording(with: binding)
        }
    }

    /// A hold binding went down.
    private func handleHoldPress(binding: ModeBinding) {
        let bindingId = binding.bindingId
        // Ignore repeated down while already holding this binding.
        guard holdState[bindingId] != true else { return }

        if activeRecordingBindingId != nil {
            if activeRecordingModeId == binding.modeId {
                // Same mode recording via another binding: this press just stops it.
                // Do not begin a hold recording, so the eventual release is a no-op.
                stopActiveRecording()
            } else {
                // Different mode: finish the current recording through the app's policy.
                clearActiveRecordingState()
                onCrossModeFinish?(binding.modeId)
            }
            return
        }

        // Idle: begin hold recording.
        holdState[bindingId] = true
        startSafetyTimer(for: binding)
        startRecording(with: binding)
    }

    /// A hold binding was released.
    private func handleHoldRelease(binding: ModeBinding) {
        let bindingId = binding.bindingId
        guard holdState[bindingId] == true else { return }
        holdState[bindingId] = false
        cancelSafetyTimer(for: bindingId)
        if activeRecordingBindingId == bindingId {
            stopActiveRecording()
        }
    }

    // MARK: - Active recording lifecycle

    private func startRecording(with binding: ModeBinding) {
        activeRecordingBindingId = binding.bindingId
        activeRecordingModeId = binding.modeId
        binding.onStart()
    }

    /// Stop the active recording, invoking its binding's `onStop`.
    private func stopActiveRecording() {
        let active = activeRecordingBinding()
        clearActiveRecordingState()
        active?.onStop()
    }

    /// Clear all active-recording bookkeeping. This is the single point where an in-flight
    /// recording is torn down, regardless of the trigger (same-mode second binding,
    /// cross-mode toggle/hold, ESC, safety timer, reset, …). Before dropping the active
    /// binding id we clear its hold-side state (`holdState` + safety timer), so a hold
    /// binding that is interrupted mid-recording by another binding/mode cannot leave a
    /// dangling 120s safety timer that later fires `handleHoldSafetyTimer` and invokes
    /// `onStop` a second time on an already-stopped session ("ghost stop"). On the timer
    /// self-fire path the hold state is already cleared by `handleHoldSafetyTimer`, so
    /// clearing here is a safe no-op.
    /// Clear all active-recording bookkeeping. This is the single point where an in-flight
    /// recording is torn down, regardless of the trigger (same-mode second binding,
    /// cross-mode toggle/hold, ESC, safety timer, reset, …). Before dropping the active
    /// binding id we clear its hold-side state (`holdState` + safety timer), so a hold
    /// binding that is interrupted mid-recording by another binding/mode cannot leave a
    /// dangling 120s safety timer that later fires `handleHoldSafetyTimer` and invokes
    /// `onStop` a second time on an already-stopped session ("ghost stop"). On the timer
    /// self-fire path the hold state is already cleared by `handleHoldSafetyTimer`, so
    /// clearing here is a safe no-op.
    private func clearActiveRecordingState() {
        if let activeId = activeRecordingBindingId {
            holdState[activeId] = false
            cancelSafetyTimer(for: activeId)
        }
        activeRecordingBindingId = nil
        activeRecordingModeId = nil
    }

    private func activeRecordingBinding() -> ModeBinding? {
        guard let id = activeRecordingBindingId else { return nil }
        return bindings.first { $0.bindingId == id }
    }

    // MARK: - Test SPI (internal)
    //
    // Exposes a thin driver + read-only views of the state machine so unit tests can
    // replay the hold/toggle/cross-mode paths and assert no ghost hold state or timers
    // are left behind. These members are `internal` (not `private`) so the `@testable
    // import Type4Me` test target can reach them; they are not used by production code.

    /// Drive the state machine the same way a real key event would (press or release).
    internal func simulateBindingEvent(_ binding: ModeBinding, pressed: Bool) {
        handleBindingEvent(binding: binding, pressed: pressed)
    }

    /// Drive the modifier-combo evaluator with synthetic flags. This covers the
    /// prefix-delay path used by modifier-only bindings such as fn and fn+Shift.
    @discardableResult
    internal func simulateModifierFlags(_ flags: CGEventFlags) -> Bool {
        evaluateModifierBindings(currentFlags: flags)
    }

    /// Stop the active recording (same path as ESC / safety timer / reset).
    internal func simulateStopActiveRecording() {
        stopActiveRecording()
    }

    /// True when a hold binding's press has been recorded but not yet released/stopped.
    internal func isHoldActive(for bindingId: UUID) -> Bool {
        holdState[bindingId] == true
    }

    /// True when this binding currently owns the active recording.
    internal func isActiveRecordingBinding(_ bindingId: UUID) -> Bool {
        activeRecordingBindingId == bindingId
    }

    /// True if a safety timer is still pending for this binding (would fire later).
    internal func hasPendingSafetyTimer(for bindingId: UUID) -> Bool {
        holdSafetyTimers[bindingId] != nil
    }

    // MARK: - Modifier Combo Evaluation

    /// Order-independent evaluation of modifier-only combos (e.g. `fn`, `Ctrl+Shift`,
    /// `fn+Shift`). A combo is active when the full set of currently-held modifier flags
    /// exactly equals the combo's flags, regardless of the order the keys were pressed.
    /// At most one combo matches at a time. Prefix combos (e.g. `fn` when `fn+Shift`
    /// also exists) are deferred so the longer combo wins when both are being formed.
    /// - Returns: `true` when the current flags exactly match a registered combo, so the
    ///   caller can swallow the event and suppress the modifier's own system behavior.
    @discardableResult
    private func evaluateModifierBindings(currentFlags: CGEventFlags) -> Bool {
        let current = normalizedModifierFlags(currentFlags)
        let previous = previousModifierFlags
        previousModifierFlags = current

        let matched = bindings.first { b in
            guard isModifierKeyCode(b.keyCode), !b.isMouseButton, !b.isMediaKey,
                  let expected = ModeBinding.fullModifierFlags(
                      keyCode: Int(b.keyCode), modifiers: b.modifiers.rawValue)
            else { return false }
            return expected == current
        }
        let shouldSwallow = matched != nil

        guard matched?.bindingId != activeModifierComboBindingId else { return shouldSwallow }

        // Release the previously-active combo.
        if let activeId = activeModifierComboBindingId,
           let activeBinding = bindings.first(where: { $0.bindingId == activeId }) {
            activeModifierComboBindingId = nil
            let activeExpected = ModeBinding.fullModifierFlags(
                keyCode: Int(activeBinding.keyCode), modifiers: activeBinding.modifiers.rawValue) ?? []
            let buildingIntoLargerCombo = activeExpected != current && activeExpected.isSubset(of: current)
            if buildingIntoLargerCombo, pendingModifierTriggers[activeId] != nil {
                // We're extending a deferred prefix (e.g. fn → fn+Shift) into the longer
                // combo. Drop the pending prefix trigger silently; do NOT fire it as a tap.
                cancelPendingModifierTriggers()
            } else if !consumePendingModifierRelease(for: activeBinding) {
                handleBindingEvent(binding: activeBinding, pressed: false)
            }
        }

        // Press the newly-active combo (if any).
        guard let matched, !current.isEmpty,
              let expected = ModeBinding.fullModifierFlags(
                  keyCode: Int(matched.keyCode), modifiers: matched.modifiers.rawValue)
        else { return shouldSwallow }

        // Arriving here by releasing a *larger* combo down through this one (previous
        // flags were a strict superset) is a release transient, not a deliberate press:
        // don't trigger, and don't mark active so the following release is a clean no-op.
        if expected != previous && expected.isSubset(of: previous) { return shouldSwallow }

        activeModifierComboBindingId = matched.bindingId
        if shouldDeferModifierTrigger(for: matched) {
            schedulePendingModifierTrigger(for: matched)
        } else {
            cancelPendingModifierTriggers()
            handleBindingEvent(binding: matched, pressed: true)
        }
        return shouldSwallow
    }

    // MARK: - Modifier Prefix Conflicts

    private func shouldDeferModifierTrigger(for binding: ModeBinding) -> Bool {
        guard isModifierKeyCode(binding.keyCode) else { return false }

        return bindings.contains { other in
            guard other.bindingId != binding.bindingId,
                  !other.isMouseButton,
                  !other.isMediaKey
            else { return false }
            return ModeBinding.modifierBindingIsPrefix(
                modifierKeyCode: Int(binding.keyCode),
                modifierModifiers: binding.modifiers.rawValue,
                otherKeyCode: Int(other.keyCode),
                otherModifiers: other.modifiers.rawValue
            )
        }
    }

    private func schedulePendingModifierTrigger(for binding: ModeBinding) {
        cancelPendingModifierTriggers(except: binding.bindingId)
        let token = UUID()
        pendingModifierTriggers[binding.bindingId] = PendingModifierTrigger(binding: binding, token: token)
        DebugFileLogger.log(
            "hotkey modifier prefix pending keyCode=\(binding.keyCode) style=\(binding.style.rawValue) recording=\(activeRecordingBindingId != nil) delayMs=\(Int(modifierPrefixTriggerDelay * 1_000))"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + modifierPrefixTriggerDelay) { [weak self] in
            self?.firePendingModifierTrigger(bindingId: binding.bindingId, token: token)
        }
    }

    private func firePendingModifierTrigger(bindingId: UUID, token: UUID) {
        guard let pending = pendingModifierTriggers[bindingId],
              pending.token == token,
              isExactModifierComboActive(for: pending.binding)
        else { return }
        pendingModifierTriggers.removeValue(forKey: bindingId)
        DebugFileLogger.log(
            "hotkey modifier prefix fired keyCode=\(pending.binding.keyCode) style=\(pending.binding.style.rawValue) recording=\(activeRecordingBindingId != nil)"
        )
        handleBindingEvent(binding: pending.binding, pressed: true)
    }

    private func consumePendingModifierRelease(for binding: ModeBinding) -> Bool {
        guard let pending = pendingModifierTriggers.removeValue(forKey: binding.bindingId) else { return false }

        // A quick prefix tap while another binding is already recording is an explicit
        // stop request, not an attempted hold start. Dispatch the short press before
        // applying the idle-only hold suppression below. This is especially important
        // for the default Fn / Fn+Shift pair: a translation started with Fn+Shift must
        // still be stoppable by a quick tap of Fn.
        if activeRecordingBindingId != nil {
            DebugFileLogger.log(
                "hotkey modifier prefix quick release dispatched keyCode=\(pending.binding.keyCode) style=\(pending.binding.style.rawValue) action=finishRecording"
            )
            handleBindingEvent(binding: pending.binding, pressed: true)
            handleBindingEvent(binding: pending.binding, pressed: false)
            return true
        }

        // A hold binding released before its prefix delay elapsed was never
        // physically active. Starting and stopping it back-to-back is both
        // useless and racy: onStart schedules the recording asynchronously,
        // so onStop can run first and observe an idle UI, leaving the later
        // recording start unstopped. A quick release should therefore cancel
        // the pending hold entirely. Toggle bindings still need a synthesized
        // press/release so a quick tap retains toggle semantics.
        guard pending.binding.style == .toggle else {
            DebugFileLogger.log(
                "hotkey modifier prefix quick release ignored keyCode=\(pending.binding.keyCode) style=\(pending.binding.style.rawValue) reason=idleHold"
            )
            return true
        }
        handleBindingEvent(binding: pending.binding, pressed: true)
        handleBindingEvent(binding: pending.binding, pressed: false)
        return true
    }

    private func cancelPendingModifierTriggers(except bindingId: UUID? = nil) {
        let ids = pendingModifierTriggers.keys.filter { $0 != bindingId }
        for id in ids {
            pendingModifierTriggers.removeValue(forKey: id)
        }
    }

    private func isExactModifierComboActive(for binding: ModeBinding) -> Bool {
        guard let expected = ModeBinding.fullModifierFlags(
            keyCode: Int(binding.keyCode),
            modifiers: binding.modifiers.rawValue
        ) else { return false }

        // `CGEventSource.flagsState` does not reliably report `.maskSecondaryFn`
        // while Fn is held. The event tap has already observed the authoritative
        // flagsChanged state, and updates `previousModifierFlags` before scheduling
        // the prefix delay. Use that state so a deferred Fn hold can actually fire;
        // a release event clears it before the pending trigger gets a chance to run.
        return previousModifierFlags == expected
    }

    // MARK: - Safety Timer

    private func startSafetyTimer(for binding: ModeBinding) {
        cancelSafetyTimer(for: binding.bindingId)
        let id = binding.bindingId
        holdSafetyTimers[id] = Timer.scheduledTimer(
            timeInterval: maxHoldDuration,
            target: self,
            selector: #selector(handleHoldSafetyTimer(_:)),
            userInfo: id,
            repeats: false
        )
    }

    private func cancelSafetyTimer(for id: UUID) {
        holdSafetyTimers[id]?.invalidate()
        holdSafetyTimers[id] = nil
    }

    @objc
    private func handleHoldSafetyTimer(_ timer: Timer) {
        guard let id = timer.userInfo as? UUID else { return }
        guard holdState[id] == true else { return }
        guard let binding = bindings.first(where: { $0.bindingId == id }) else { return }

        NSLog("[HotkeyManager] Safety timer fired for binding %@, auto-stopping", id.uuidString)
        holdState[id] = false
        if activeRecordingBindingId == id {
            stopActiveRecording()
        } else {
            binding.onStop()
        }
    }

    // MARK: - Stuck Hold Recovery

    /// After a tap re-enable, check if any held keys were released while the tap was disabled.
    private func recoverStuckHolds() {
        let currentFlags = CGEventSource.flagsState(.combinedSessionState)

        for binding in bindings where binding.style == .hold {
            let id = binding.bindingId
            guard holdState[id] == true else { continue }

            // Mouse buttons and media keys: no API to query current state, rely on release events instead.
            // Safety timer will catch truly stuck holds.
            if binding.isMouseButton || binding.isMediaKey { continue }

            let stillDown: Bool
            if isModifierKeyCode(binding.keyCode) {
                stillDown = isModifierPressed(keyCode: binding.keyCode, flags: currentFlags)
            } else {
                stillDown = CGEventSource.keyState(.combinedSessionState, key: binding.keyCode)
            }

            if !stillDown {
                NSLog("[HotkeyManager] Recovering stuck hold for binding %@", id.uuidString)
                holdState[id] = false
                cancelSafetyTimer(for: id)
                if activeRecordingBindingId == id {
                    stopActiveRecording()
                } else {
                    binding.onStop()
                }
            }
        }
    }

    // MARK: - Helpers

    private static func isKnownMediaKeyType(_ keyType: Int) -> Bool {
        // NX_KEYTYPE values from IOKit/hidsystem/IOHIDParameter.h
        // SOUND_UP=0, SOUND_DOWN=1, MUTE=7, PLAY=16, NEXT=17, PREVIOUS=18, FAST=19, REWIND=20
        [0, 1, 7, 16, 17, 18, 19, 20].contains(keyType)
    }

    private func isModifierKeyCode(_ keyCode: CGKeyCode) -> Bool {
        ModeBinding.isModifierKeyCode(Int(keyCode))
    }

    private func normalizedModifierFlags(_ flags: CGEventFlags, forKeyCode keyCode: Int? = nil) -> CGEventFlags {
        ModeBinding.normalizedModifierFlags(flags, forKeyCode: keyCode)
    }

    private func modifierEventFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        ModeBinding.modifierEventFlag(for: Int(keyCode))
    }

    private func isModifierPressed(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return false
        }
    }

    // MARK: - Media Session (prevent Apple Music auto-launch)

    /// Register as an active media session when transport media keys (play/next/prev)
    /// are bound as hotkeys, so the system doesn't launch Apple Music on key press.
    private func updateMediaKeySession() {
        for (command, token) in mediaCommandTokens {
            command.removeTarget(token)
        }
        mediaCommandTokens = []

        // Find which transport key types are bound (volume keys don't launch Apple Music)
        let boundKeyTypes = Set(bindings.filter(\.isMediaKey).map { ModeBinding.mediaKeyType(from: Int($0.keyCode)) })
        let transportKeyTypes: Set<Int> = [16, 17, 18, 19, 20]
        let boundTransportKeys = boundKeyTypes.intersection(transportKeyTypes)

        if boundTransportKeys.isEmpty {
            if isMediaSessionActive {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                MPNowPlayingInfoCenter.default().playbackState = .stopped
                isMediaSessionActive = false
                NSLog("[HotkeyManager] Deactivated media session (no transport keys bound)")
            }
            return
        }

        let commandCenter = MPRemoteCommandCenter.shared()

        if !isMediaSessionActive {
            // Must set non-empty NowPlaying info with playbackState=.playing —
            // mediaremoted on macOS 15 ignores apps with empty nowPlayingInfo.
            let nowPlayingInfo: [String: Any] = [
                MPMediaItemPropertyTitle: "Type4Me Voice Input",
                MPNowPlayingInfoPropertyPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            ]
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            MPNowPlayingInfoCenter.default().playbackState = .playing
            isMediaSessionActive = true
            NSLog("[HotkeyManager] Activated media session (transport keys bound)")
        }

        let handler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { event in
            NSLog("[HotkeyManager] Media remote command received: %@", String(describing: type(of: event)))
            return .success
        }

        if boundTransportKeys.contains(16) {
            commandCenter.playCommand.isEnabled = true
            commandCenter.pauseCommand.isEnabled = true
            commandCenter.togglePlayPauseCommand.isEnabled = true

            let playToken = commandCenter.playCommand.addTarget(handler: handler)
            let pauseToken = commandCenter.pauseCommand.addTarget(handler: handler)
            let toggleToken = commandCenter.togglePlayPauseCommand.addTarget(handler: handler)
            mediaCommandTokens.append(contentsOf: [
                (command: commandCenter.playCommand, token: playToken),
                (command: commandCenter.pauseCommand, token: pauseToken),
                (command: commandCenter.togglePlayPauseCommand, token: toggleToken),
            ])
        }
        if boundTransportKeys.contains(17) {
            commandCenter.nextTrackCommand.isEnabled = true
            let token = commandCenter.nextTrackCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.nextTrackCommand, token: token))
        }
        if boundTransportKeys.contains(18) {
            commandCenter.previousTrackCommand.isEnabled = true
            let token = commandCenter.previousTrackCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.previousTrackCommand, token: token))
        }
        if boundTransportKeys.contains(19) {
            commandCenter.seekForwardCommand.isEnabled = true
            let token = commandCenter.seekForwardCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.seekForwardCommand, token: token))
        }
        if boundTransportKeys.contains(20) {
            commandCenter.seekBackwardCommand.isEnabled = true
            let token = commandCenter.seekBackwardCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.seekBackwardCommand, token: token))
        }
    }

    private func deactivateMediaKeySession() {
        for (command, token) in mediaCommandTokens {
            command.isEnabled = false
            command.removeTarget(token)
        }
        mediaCommandTokens = []
        if isMediaSessionActive {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            isMediaSessionActive = false
            NSLog("[HotkeyManager] Deactivated media session (stop)")
        }
    }
}

// MARK: - C callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(type: type, event: event)
}
