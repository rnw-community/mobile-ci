import XCTest
@testable import FixtureCore

final class FixtureCoreTests: XCTestCase {
    func testSumOfNothingIsZero() {
        XCTAssertEqual(FixtureCore.sum([]), 0)
    }

    func testSumAddsEveryValue() {
        XCTAssertEqual(FixtureCore.sum([1, 2, 3, 4]), 10)
    }
}
