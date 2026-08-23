import XCTest
@testable import Type4Me

@MainActor
final class MenuBarControlCenterTests: XCTestCase {

    func testApplicationMenuDestinationsUseDeterministicTabs() {
        XCTAssertEqual(MenuBarApplicationDestination.home.settingsTab, .general)
        XCTAssertEqual(MenuBarApplicationDestination.settings.settingsTab, .preferences)
        XCTAssertEqual(MenuBarApplicationDestination.models.settingsTab, .models)
    }

    func testRefreshNotificationsIncludeApplicationActivationForPermissionChanges() {
        XCTAssertTrue(
            MenuBarControlCenterModel.refreshNotificationNames.contains(
                NSApplication.didBecomeActiveNotification
            )
        )
    }

    func testReadyStatesAllowDictationStart() {
        XCTAssertTrue(MenuBarPresentation.canStartRecording(in: .hidden))
        XCTAssertTrue(MenuBarPresentation.canStartRecording(in: .done))
        XCTAssertTrue(MenuBarPresentation.canStartRecording(in: .error))
    }

    func testActiveAndProcessingStatesBlockDictationStart() {
        XCTAssertFalse(MenuBarPresentation.canStartRecording(in: .preparing))
        XCTAssertFalse(MenuBarPresentation.canStartRecording(in: .recording))
        XCTAssertFalse(MenuBarPresentation.canStartRecording(in: .processing))
        XCTAssertFalse(MenuBarPresentation.canStartRecording(in: .recovering))
    }

    func testOnlyCaptureStatesLockNextRecordingSettings() {
        XCTAssertTrue(MenuBarPresentation.locksRuntimeSettings(in: .preparing))
        XCTAssertTrue(MenuBarPresentation.locksRuntimeSettings(in: .recording))
        XCTAssertFalse(MenuBarPresentation.locksRuntimeSettings(in: .processing))
        XCTAssertFalse(MenuBarPresentation.locksRuntimeSettings(in: .recovering))
        XCTAssertFalse(MenuBarPresentation.locksRuntimeSettings(in: .done))
        XCTAssertFalse(MenuBarPresentation.locksRuntimeSettings(in: .error))
        XCTAssertFalse(MenuBarPresentation.locksRuntimeSettings(in: .hidden))
    }
}
