// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Verifies a timed-out ScreenCaptureKit operation cannot queue more captures.
// ABOUTME: Exercises cancellation-unresponsive work without invoking the system capture API.

import Foundation
import XCTest
@testable import mirroir_mcp

final class ScreenCaptureKitShotTests: XCTestCase {
    func testTimedOutCaptureRemainsSingleFlightUntilWorkerExits() {
        let stalled = NonCooperativeCapture()
        defer { stalled.release() }

        let first = ScreenCaptureKitShot.captureData(timeout: .seconds(1)) {
            await stalled.capture()
        }
        XCTAssertNil(first)
        XCTAssertEqual(stalled.started.wait(timeout: .now() + .seconds(1)), .success)
        XCTAssertEqual(stalled.callCount, 1)

        let busyStart = Date()
        let second = ScreenCaptureKitShot.captureData(timeout: .seconds(1)) {
            Data([2])
        }
        XCTAssertNil(second, "a cancelled but still-running capture must retain the permit")
        XCTAssertLessThan(Date().timeIntervalSince(busyStart), 0.5)
        XCTAssertEqual(stalled.callCount, 1)

        stalled.release()
        XCTAssertEqual(stalled.finished.wait(timeout: .now() + .seconds(1)), .success)

        let recoveryDeadline = Date().addingTimeInterval(2)
        var recovered: Data?
        repeat {
            recovered = ScreenCaptureKitShot.captureData(timeout: .seconds(1)) {
                Data([3])
            }
            if recovered == nil { usleep(10_000) }
        } while recovered == nil && Date() < recoveryDeadline
        XCTAssertEqual(recovered, Data([3]))
    }
}

/// A continuation does not resume when its task is cancelled, modeling a
/// ScreenCaptureKit call whose underlying framework request remains in flight.
private final class NonCooperativeCapture: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var pending: CheckedContinuation<Data?, Never>?
    private var storedCallCount = 0

    var callCount: Int { lock.withLock { storedCallCount } }

    func capture() async -> Data? {
        let result: Data? = await withCheckedContinuation { continuation in
            lock.withLock {
                storedCallCount += 1
                pending = continuation
            }
            started.signal()
        }
        finished.signal()
        return result
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
            let current = pending
            pending = nil
            return current
        }
        continuation?.resume(returning: Data([1]))
    }
}
