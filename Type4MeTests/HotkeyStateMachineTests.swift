import XCTest
@testable import Type4Me

/// Thread-safe counters for capturing ModeBinding onStart/onStop invocation counts.
final class BindingCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0

    func recordStart() {
        lock.lock(); _startCount += 1; lock.unlock()
    }
    func recordStop() {
        lock.lock(); _stopCount += 1; lock.unlock()
    }

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return _startCount }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
}

/// State-machine regression tests for the multi-hotkey P0 "ghost hold" fix.
///
/// Before the fix, stopping a hold-initiated recording via any path other than the
/// binding's own release left `holdState[bindingId] == true` and a running 120s safety
/// timer. When the timer eventually fired, `handleHoldSafetyTimer` saw the stale
/// hold state, passed its guard, and invoked `onStop` a second time on a session that
/// was no longer recording — a "ghost stop". These tests exercise the three stop
/// paths (same-mode second binding, cross-mode toggle, cross-mode hold) plus the
/// direct stop path and assert no residual hold state, no pending safety timer, and
/// exactly one `onStop` per binding.
final class HotkeyStateMachineTests: XCTestCase {

    // MARK: - Fixtures

    private func makeManager() -> HotkeyManager {
        let manager = HotkeyManager()
        manager.registerBindings([]) // initialize dictionaries + media key session
        return manager
    }

    private func makeHoldBinding(modeId: UUID, counters: BindingCounters) -> ModeBinding {
        ModeBinding(
            bindingId: UUID(),
            modeId: modeId,
            keyCode: 42,                       // arbitrary non-modifier keyCode
            modifiers: [],
            style: .hold,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() }
        )
    }

    private func makeToggleBinding(modeId: UUID, counters: BindingCounters) -> ModeBinding {
        ModeBinding(
            bindingId: UUID(),
            modeId: modeId,
            keyCode: 43,
            modifiers: [],
            style: .toggle,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() }
        )
    }

    private func makeFnBinding(
        style: ProcessingMode.HotkeyStyle,
        modeId: UUID,
        counters: BindingCounters
    ) -> ModeBinding {
        ModeBinding(
            bindingId: UUID(),
            modeId: modeId,
            keyCode: 63,
            modifiers: [],
            style: style,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() }
        )
    }

    private func makeFnShiftBinding(modeId: UUID, counters: BindingCounters) -> ModeBinding {
        ModeBinding(
            bindingId: UUID(),
            modeId: modeId,
            keyCode: 56,
            modifiers: .maskSecondaryFn,
            style: .toggle,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() }
        )
    }

    // MARK: - Tests

    /// Direct stop path: hold press → stopActiveRecording. Before the fix this path
    /// also left `holdState`/timer set; now `clearActiveRecordingState` cleans them.
    func testStopActiveRecordingClearsHoldStateAndSafetyTimer() {
        let manager = makeManager()
        let counters = BindingCounters()
        let binding = makeHoldBinding(modeId: UUID(), counters: counters)

        manager.registerBindings([binding])
        manager.simulateBindingEvent(binding, pressed: true)

        XCTAssertTrue(manager.isHoldActive(for: binding.bindingId))
        XCTAssertTrue(manager.isActiveRecordingBinding(binding.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: binding.bindingId))
        XCTAssertEqual(counters.startCount, 1)
        XCTAssertEqual(counters.stopCount, 0)

        manager.simulateStopActiveRecording()

        XCTAssertFalse(manager.isHoldActive(for: binding.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(binding.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: binding.bindingId))
        XCTAssertEqual(counters.stopCount, 1, "onStop must be called exactly once")
    }

    /// Path 1: hold recording → same-mode second toggle press. The second press just
    /// stops the recording; it must not start a new one or leave the first binding's
    /// hold state/timer behind.
    func testHoldRecording_sameModeSecondTogglePressStopsWithoutGhostHold() {
        let manager = makeManager()
        let counters = BindingCounters()
        let modeId = UUID()
        let hold = makeHoldBinding(modeId: modeId, counters: counters)
        let toggle = makeToggleBinding(modeId: modeId, counters: counters)

        manager.registerBindings([hold, toggle])
        manager.simulateBindingEvent(hold, pressed: true)

        XCTAssertEqual(counters.startCount, 1)
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertTrue(manager.isHoldActive(for: hold.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: hold.bindingId))

        manager.simulateBindingEvent(toggle, pressed: true)

        XCTAssertFalse(manager.isHoldActive(for: hold.bindingId),
                       "same-mode second binding must clear the hold binding's holdState")
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: hold.bindingId),
                       "same-mode second binding must cancel the hold binding's safety timer")
        XCTAssertFalse(manager.isActiveRecordingBinding(hold.bindingId))
        XCTAssertEqual(counters.startCount, 1, "second binding in same mode must not start a new recording")
        XCTAssertEqual(counters.stopCount, 1, "onStop must fire exactly once for the hold recording")
    }

    /// Path 2: hold recording (mode A) → cross-mode toggle press (mode B). The toggle
    /// hands off to the new mode via `onCrossModeStop`; it must also clear the former
    /// hold binding's state and timer so the safety timer can't ghost-stop it later.
    func testHoldRecording_crossModeToggleClearsFormerHold() {
        let manager = makeManager()
        let counters = BindingCounters()
        let modeA = UUID()
        let modeB = UUID()
        let hold = makeHoldBinding(modeId: modeA, counters: counters)
        let toggle = makeToggleBinding(modeId: modeB, counters: counters)

        var crossModeStops: [UUID] = []
        manager.onCrossModeStop = { crossModeStops.append($0) }

        manager.registerBindings([hold, toggle])
        manager.simulateBindingEvent(hold, pressed: true)

        XCTAssertTrue(manager.isHoldActive(for: hold.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: hold.bindingId))

        manager.simulateBindingEvent(toggle, pressed: true)

        XCTAssertFalse(manager.isHoldActive(for: hold.bindingId),
                       "cross-mode stop must clear the former hold binding's holdState")
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: hold.bindingId),
                       "cross-mode stop must cancel the former hold binding's safety timer")
        XCTAssertEqual(crossModeStops, [modeB],
                       "onCrossModeStop must fire exactly once with the new mode's id")
        XCTAssertEqual(counters.stopCount, 0,
                       "cross-mode stop must not invoke the former binding's onStop (mode switch, not same-mode stop)")
    }

    /// Path 3: hold recording (mode A) → cross-mode hold press (mode B). Same expected
    /// cleanup as path 2; the new mode's hold does not begin recording because the
    /// cross-mode branch hands off to `onCrossModeStop`.
    func testHoldRecording_crossModeHoldClearsFormerHold() {
        let manager = makeManager()
        let counters = BindingCounters()
        let modeA = UUID()
        let modeB = UUID()
        let holdA = makeHoldBinding(modeId: modeA, counters: counters)
        let holdB = makeHoldBinding(modeId: modeB, counters: counters)

        var crossModeStops: [UUID] = []
        manager.onCrossModeStop = { crossModeStops.append($0) }

        manager.registerBindings([holdA, holdB])
        manager.simulateBindingEvent(holdA, pressed: true)

        XCTAssertTrue(manager.isHoldActive(for: holdA.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: holdA.bindingId))

        manager.simulateBindingEvent(holdB, pressed: true)

        XCTAssertFalse(manager.isHoldActive(for: holdA.bindingId),
                       "cross-mode hold must clear the former hold binding's holdState")
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: holdA.bindingId),
                       "cross-mode hold must cancel the former hold binding's safety timer")
        XCTAssertFalse(manager.isHoldActive(for: holdB.bindingId),
                       "cross-mode hold must not begin a new hold recording (it hands off to onCrossModeStop)")
        XCTAssertEqual(crossModeStops, [modeB])
        XCTAssertEqual(counters.stopCount, 0)
    }

    /// Regression: a normal hold release still clears state and fires onStop exactly once.
    /// Ensures the unified `clearActiveRecordingState` cleanup didn't break the happy path.
    func testHoldReleaseClearsStateAndStopsOnce() {
        let manager = makeManager()
        let counters = BindingCounters()
        let binding = makeHoldBinding(modeId: UUID(), counters: counters)

        manager.registerBindings([binding])
        manager.simulateBindingEvent(binding, pressed: true)

        XCTAssertTrue(manager.isHoldActive(for: binding.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: binding.bindingId))

        manager.simulateBindingEvent(binding, pressed: false)

        XCTAssertFalse(manager.isHoldActive(for: binding.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: binding.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(binding.bindingId))
        XCTAssertEqual(counters.stopCount, 1, "onStop must be called exactly once on release")
    }

    /// Regression: fn is deferred when fn+Shift is also bound. A quick fn tap
    /// releases before that delay and must not enqueue an asynchronous recording
    /// start after its stop has already been ignored by the idle UI.
    func testQuickFnReleaseBeforePrefixDelayDoesNotStartHoldBinding() {
        let manager = makeManager()
        let counters = BindingCounters()
        let fnHold = makeFnBinding(style: .hold, modeId: UUID(), counters: counters)
        let fnShift = makeFnShiftBinding(modeId: UUID(), counters: counters)
        manager.registerBindings([fnHold, fnShift])

        manager.simulateModifierFlags(.maskSecondaryFn)
        manager.simulateModifierFlags([])

        XCTAssertEqual(counters.startCount, 0)
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertFalse(manager.isHoldActive(for: fnHold.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(fnHold.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: fnHold.bindingId))
    }

    /// Toggle bindings intentionally treat the same quick prefix tap as a press,
    /// so the hold-only fix must not remove their established behavior.
    func testQuickFnReleaseBeforePrefixDelayStillStartsToggleBinding() {
        let manager = makeManager()
        let counters = BindingCounters()
        let fnToggle = makeFnBinding(style: .toggle, modeId: UUID(), counters: counters)
        let fnShift = makeFnShiftBinding(modeId: UUID(), counters: counters)
        manager.registerBindings([fnToggle, fnShift])

        manager.simulateModifierFlags(.maskSecondaryFn)
        manager.simulateModifierFlags([])

        XCTAssertEqual(counters.startCount, 1)
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertTrue(manager.isActiveRecordingBinding(fnToggle.bindingId))
    }

    /// Regression: Fn's state is not reliably present in
    /// `CGEventSource.flagsState(.combinedSessionState)`. A hold that remains down
    /// beyond the prefix delay must use the event tap's observed flags and start.
    func testHeldFnPastPrefixDelayStartsAndReleaseStopsHoldBinding() {
        let defaults = UserDefaults.standard
        let key = HotkeyManager.modifierPrefixTriggerDelayKey
        let priorValue = defaults.object(forKey: key)
        defaults.set(0.02, forKey: key)
        defer {
            if let priorValue {
                defaults.set(priorValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let manager = makeManager()
        let counters = BindingCounters()
        let fnHold = makeFnBinding(style: .hold, modeId: UUID(), counters: counters)
        let fnShift = makeFnShiftBinding(modeId: UUID(), counters: counters)
        manager.registerBindings([fnHold, fnShift])

        manager.simulateModifierFlags(.maskSecondaryFn)

        let delayElapsed = expectation(description: "modifier prefix delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            delayElapsed.fulfill()
        }
        wait(for: [delayElapsed], timeout: 0.5)

        XCTAssertEqual(counters.startCount, 1)
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertTrue(manager.isHoldActive(for: fnHold.bindingId))
        XCTAssertTrue(manager.isActiveRecordingBinding(fnHold.bindingId))

        manager.simulateModifierFlags([])

        XCTAssertEqual(counters.stopCount, 1)
        XCTAssertFalse(manager.isHoldActive(for: fnHold.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(fnHold.bindingId))
    }
}
