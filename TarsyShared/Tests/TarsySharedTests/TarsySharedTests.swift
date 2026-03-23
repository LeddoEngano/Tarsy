import XCTest
@testable import TarsyShared

final class TarsySharedTests: XCTestCase {
    func testConfigValues() {
        XCTAssertEqual(TarsyConfig.websocketPort, 8642)
        XCTAssertFalse(TarsyConfig.supabaseAnonKey.isEmpty)
    }
}
