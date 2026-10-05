// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests screenshot settling and non-activating launch capture isolation.
// ABOUTME: Ensures a slow first frame is returned without another slow capture.

import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import mirroir_mcp

final class ScreenCaptureBudgetTests: XCTestCase {

    func testSlowFirstFrameDoesNotStartAnotherCapture() {
        let capture = CountingCapture(delayUs: 20_000)

        let result = capture.captureSettledWithInfo(timeoutUs: 1_000)

        XCTAssertNotNil(result)
        XCTAssertEqual(capture.captureCount, 1)
    }

    func testExpiredDeadlineAfterPollDoesNotStartAnotherCapture() {
        let capture = CountingCapture(delayUs: 0)

        let result = capture.captureSettledWithInfo(timeoutUs: 10_000)

        XCTAssertNotNil(result)
        XCTAssertEqual(capture.captureCount, 1)
    }

    func testLaunchScreenshotWithoutWindowIDNeverActivatesFallback() {
        let bridge = ActivationCountingBridge()
        let capture = ScreenCapture(bridge: bridge)

        XCTAssertNil(capture.captureNonActivatingData())
        XCTAssertEqual(bridge.activationCount, 0)
    }
}

private final class CountingCapture: ScreenCapturing, @unchecked Sendable {
    private(set) var captureCount = 0
    private let delayUs: UInt32
    private let info = WindowInfo(
        windowID: 1, position: .zero, size: CGSize(width: 100, height: 100), pid: 1)

    init(delayUs: UInt32) { self.delayUs = delayUs }

    func captureWithInfo() -> CaptureResult? {
        captureCount += 1
        if delayUs > 0 { usleep(delayUs) }
        return CaptureResult(data: Data([1]), info: info)
    }

    func captureData() -> Data? { captureWithInfo()?.data }
    func captureBase64() -> String? { captureData()?.base64EncodedString() }
}

private final class ActivationCountingBridge: WindowBridging, @unchecked Sendable {
    let targetName = "iphone"
    private(set) var activationCount = 0

    func findProcess() -> NSRunningApplication? { nil }
    func getWindowInfo() -> WindowInfo? {
        WindowInfo(windowID: 0, position: .zero, size: CGSize(width: 100, height: 100), pid: 1)
    }
    func getState() -> WindowState { .connected }
    func getOrientation() -> DeviceOrientation? { .portrait }
    func activate() { activationCount += 1 }
    func isFrontmost() -> Bool { true }
}
