import XCTest
@testable import Type4Me

final class VolcASRClientTests: XCTestCase {
    func testAuthHeadersUseSingleAPIKey() {
        let headers = VolcProtocol.authHeaders(
            apiKey: "my-api-key",
            resourceId: VolcanoASRConfig.resourceIdSeedASR,
            connectId: "connect-123"
        )

        XCTAssertEqual(headers["X-Api-Key"], "my-api-key")
        XCTAssertEqual(headers["X-Api-Resource-Id"], VolcanoASRConfig.resourceIdSeedASR)
        XCTAssertEqual(headers["X-Api-Connect-Id"], "connect-123")
    }

    func testAuthHeadersOmitRetiredCredentialHeaders() {
        let headers = VolcProtocol.authHeaders(
            apiKey: "my-api-key",
            resourceId: VolcanoASRConfig.resourceIdSeedASR,
            connectId: "connect-123"
        )

        XCTAssertNil(headers["X-Api-App-Key"])
        XCTAssertNil(headers["X-Api-Access-Key"])
        XCTAssertEqual(headers.count, 3)
    }

    func testWebSocketUpgradeProbeMessageIsIgnored() {
        let message = #"Bad Request("error", "cannot upgrade to websocket: websocket: the client is not using the websocket protocol: 'upgrade' token not found in 'Connection' header")"#

        XCTAssertTrue(VolcASRError.isWebSocketUpgradeProbeMessage(message))
    }

    func testNormalVendorErrorIsNotIgnored() {
        XCTAssertFalse(VolcASRError.isWebSocketUpgradeProbeMessage("invalid access key"))
    }
}
