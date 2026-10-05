// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests that AX reads share one deadline and each message uses the remaining budget.

import XCTest
@testable import mirroir_mcp

final class LiveMirroringProbeTests: XCTestCase {
    func testAXReadBudgetCapsEachMessageAndStopsAtOverallDeadline() {
        let budget = LiveMirroringProbe.AXReadBudget(startUptime: 100)

        XCTAssertEqual(budget.messageTimeout(at: 100), 2)
        XCTAssertEqual(budget.messageTimeout(at: 103), 2)
        XCTAssertEqual(budget.messageTimeout(at: 104.5), 0.5)
        XCTAssertNil(budget.messageTimeout(at: 105))
        XCTAssertNil(budget.messageTimeout(at: 106))
    }
}
