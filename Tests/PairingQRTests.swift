import XCTest
@testable import LuckyAgent

final class PairingQRTests: XCTestCase {
    func testLhQrJSON() {
        let raw = #"{"v":1,"url":"http://10.0.0.8:9090/","token":"secret","expires_at":"2026-10-10T00:00:00Z","ttl_hours":12,"name":"desk"}"#
        let payload = PairingQR.parse(raw)
        XCTAssertEqual(payload?.apiBase, "http://10.0.0.8:9090")
        XCTAssertEqual(payload?.apiKey, "secret")
        XCTAssertEqual(payload?.name, "desk")
    }

    func testRejectsWrongVersion() {
        XCTAssertNil(PairingQR.parse(#"{"v":2,"url":"http://10.0.0.8:9090","token":"k"}"#))
    }

    func testRejectsMissingToken() {
        XCTAssertNil(PairingQR.parse(#"{"v":1,"url":"http://10.0.0.8:9090","token":""}"#))
    }

    func testRejectsNonHTTP() {
        XCTAssertNil(PairingQR.parse(#"{"v":1,"url":"ftp://10.0.0.8","token":"k"}"#))
    }

    func testRejectsGarbage() {
        XCTAssertNil(PairingQR.parse("not a pairing code"))
        XCTAssertNil(PairingQR.parse("   "))
    }
}
