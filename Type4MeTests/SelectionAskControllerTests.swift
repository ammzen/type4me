import XCTest
@testable import Type4Me

@MainActor
final class SelectionAskControllerTests: XCTestCase {
    func testEscapeClosesVisiblePanelWhenFollowUpIsIdle() {
        let controller = SelectionAskController()
        controller.begin(question: "What does this mean?", selectedText: "Context")

        XCTAssertTrue(controller.isVisible)

        controller.handleEscape()

        XCTAssertFalse(controller.isVisible)
    }

    func testEscapeCancelsActiveFollowUpWithoutClosingPanel() {
        var cancellationCount = 0
        let controller = SelectionAskController(
            onFollowUp: { _ in true },
            onCancelFollowUp: {
                cancellationCount += 1
                return true
            }
        )
        controller.begin(question: "First question", selectedText: "Context")
        XCTAssertTrue(controller.toggleFollowUpRecording())
        XCTAssertTrue(controller.isRecordingFollowUp)

        controller.handleEscape()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(controller.isRecordingFollowUp)
        XCTAssertTrue(controller.isVisible)
        controller.hide()
    }

    func testCancelButtonActionCancelsActiveFollowUp() {
        var cancellationCount = 0
        let controller = SelectionAskController(
            onFollowUp: { _ in true },
            onCancelFollowUp: {
                cancellationCount += 1
                return true
            }
        )
        controller.begin(question: "First question", selectedText: "Context")
        XCTAssertTrue(controller.toggleFollowUpRecording())

        XCTAssertTrue(controller.cancelActiveFollowUp())

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertFalse(controller.isRecordingFollowUp)
        XCTAssertTrue(controller.isVisible)
        controller.hide()
    }

    func testFailedFollowUpDoesNotChangeRecordingState() {
        let controller = SelectionAskController(onFollowUp: { _ in false })
        controller.begin(question: "First question", selectedText: "Context")

        XCTAssertFalse(controller.toggleFollowUpRecording())
        XCTAssertFalse(controller.isRecordingFollowUp)
        controller.hide()
    }
}
