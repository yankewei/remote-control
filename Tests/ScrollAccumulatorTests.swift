import XCTest
@testable import RemoteControlCore

final class ScrollAccumulatorTests: XCTestCase {
    func testSlowScrollIsNotLost() {
        var scroll = ScrollAccumulator()
        var totalY: Int32 = 0
        for _ in 0..<12 { totalY += scroll.take(dx: 0, dy: 0.25).dy }
        XCTAssertEqual(totalY, 3)
    }

    func testRemainderKeepsSignAndDirectionChanges() {
        var scroll = ScrollAccumulator()
        XCTAssertEqual(scroll.take(dx: -0.6, dy: 0).dx, 0)
        XCTAssertEqual(scroll.take(dx: -0.6, dy: 0).dx, -1)
        // -0.2 left over; reversing direction cancels it before moving the other way.
        XCTAssertEqual(scroll.take(dx: 0.7, dy: 0).dx, 0)
        XCTAssertEqual(scroll.take(dx: 0.6, dy: 0).dx, 1)
    }

    func testWholeDeltasPassThrough() {
        var scroll = ScrollAccumulator()
        let whole = scroll.take(dx: 12, dy: -40)
        XCTAssertEqual(whole.dx, 12)
        XCTAssertEqual(whole.dy, -40)
    }
}
