import XCTest

final class BatteryRefreshGateTests: XCTestCase {
    func testIdleRequestStartsACycle() {
        var gate = BatteryRefreshGate()
        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.running)
    }

    func testRequestDuringCycleRunsOneMoreCycleAfterIt() {
        var gate = BatteryRefreshGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request()) // e.g. the keyboard came up while the apply-triggered read was in flight
        XCTAssertTrue(gate.finish())   // served by a cycle that starts after the request
        XCTAssertFalse(gate.finish())
        XCTAssertFalse(gate.running)
    }

    func testBurstDuringCycleCostsOneExtraCycle() {
        var gate = BatteryRefreshGate()
        XCTAssertTrue(gate.request())
        for _ in 0..<5 { XCTAssertFalse(gate.request()) }
        XCTAssertTrue(gate.finish())
        XCTAssertFalse(gate.finish())
    }

    func testRequestAfterCycleFinishedStartsAgain() {
        var gate = BatteryRefreshGate()
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.finish())
        XCTAssertTrue(gate.request())
    }

    func testFinishWhileIdleDoesNothing() {
        var gate = BatteryRefreshGate()
        XCTAssertFalse(gate.finish())
        XCTAssertTrue(gate.request())
    }
}
