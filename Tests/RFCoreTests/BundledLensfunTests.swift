import XCTest
@testable import RFCore

/// Lensfun 資料庫隨 App 打包，不依賴使用者另外安裝。
final class BundledLensfunTests: XCTestCase {
    func testDefaultDatabaseLoadsBundledLenses() {
        let db = LensfunDatabase.loadDefault()
        XCTAssertGreaterThan(db.lenses.count, 100)
        XCTAssertTrue(db.version.hasPrefix("lensfun:"))
    }
}
