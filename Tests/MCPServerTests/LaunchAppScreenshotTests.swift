// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests launch_app's screenshot response and bounded fallback when capture stalls.

import Foundation
import XCTest
import HelperLib
@testable import mirroir_mcp

final class LaunchAppScreenshotTests: XCTestCase {
    func testAttachesImageWithoutClaimingAppIdentity() {
        let capture = StubCapture()
        let image = Data([1, 2, 3])
        capture.captureResult = image.base64EncodedString()

        let result = LaunchAppScreenshot.outcome(appName: "拼多多", capture: capture, settleUs: 0)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.count, 2)
        guard case .text(let message) = result.content[0],
              case .image(let encoded, let mimeType) = result.content[1] else {
            return XCTFail("expected text and PNG content")
        }
        XCTAssertTrue(message.contains("请依据图像确认目标应用"))
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertEqual(Data(base64Encoded: encoded), image)
    }

    func testNoCaptureRequestsFollowUpScreenshot() {
        let result = LaunchAppScreenshot.outcome(appName: "拼多多", capture: nil)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.count, 1)
        guard case .text(let message) = result.content[0] else {
            return XCTFail("expected text content")
        }
        XCTAssertTrue(message.contains("请调用 screenshot 确认目标应用"))
    }

    func testSlowCaptureReturnsAtDeadlineWithoutWaitingForWorker() {
        let capture = BlockingLaunchCapture()
        let started = Date()
        let result = LaunchAppScreenshot.outcome(
            appName: "拼多多", capture: capture, settleUs: 0, timeout: .milliseconds(100))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(result.content.count, 1)
        capture.release.signal()
        XCTAssertEqual(capture.finished.wait(timeout: .now() + .seconds(1)), .success)
    }
}

private final class BlockingLaunchCapture: NonActivatingScreenCapturing, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    func captureNonActivatingData() -> Data? {
        release.wait()
        finished.signal()
        return nil
    }
}
