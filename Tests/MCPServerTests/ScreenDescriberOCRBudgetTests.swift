// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests bounded local OCR while preserving the captured phone screen.
// ABOUTME: A stalled recognizer cannot queue more work and normal OCR recovers afterward.

import CoreGraphics
import Foundation
import HelperLib
import ImageIO
import XCTest
@testable import mirroir_mcp

final class ScreenDescriberOCRBudgetTests: XCTestCase {
    func testTimedOutOCRReturnsScreenshotWithoutQueueingAnotherRequest() throws {
        let png = try makePNGData()
        let capture = StubCapture()
        capture.captureResult = png.base64EncodedString()
        let recognizer = BlockingTextRecognizer()
        let describer = ScreenDescriber(
            bridge: StubBridge(), capture: capture,
            textRecognizer: recognizer, describeBudget: .seconds(2))
        let otherDescriber = ScreenDescriber(
            bridge: StubBridge(), capture: capture,
            textRecognizer: recognizer, describeBudget: .seconds(2))
        defer { recognizer.releaseFirst.signal() }

        let firstStart = Date()
        let first = try XCTUnwrap(describer.describe())
        XCTAssertLessThan(Date().timeIntervalSince(firstStart), 3.0)
        XCTAssertTrue(first.ocrFailure?.contains("OCR timed out") == true)
        XCTAssertEqual(Data(base64Encoded: first.screenshotBase64), png)
        XCTAssertEqual(recognizer.callCount, 1)

        let secondStart = Date()
        let second = try XCTUnwrap(otherDescriber.describe())
        XCTAssertLessThan(Date().timeIntervalSince(secondStart), 1.5)
        XCTAssertTrue(second.ocrFailure?.contains("OCR busy") == true)
        XCTAssertEqual(Data(base64Encoded: second.screenshotBase64), png)
        XCTAssertEqual(recognizer.callCount, 1,
                       "another describer must not start a second OCR worker")

        recognizer.releaseFirst.signal()
        XCTAssertEqual(recognizer.firstFinished.wait(timeout: .now() + .seconds(2)), .success)

        let recoveryDeadline = Date().addingTimeInterval(2)
        var recovered: ScreenDescriber.DescribeResult?
        repeat {
            recovered = otherDescriber.describe()
            if recovered?.ocrFailure?.contains("OCR busy") == true {
                usleep(20_000)
            }
        } while recovered?.ocrFailure?.contains("OCR busy") == true
            && Date() < recoveryDeadline
        XCTAssertNil(recovered?.ocrFailure)
        XCTAssertEqual(recovered?.elements.first?.text, "Recovered")
        XCTAssertEqual(recognizer.callCount, 2)
    }

    private func makePNGData() throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 410, height: 898,
            bitsPerComponent: 8, bytesPerRow: 410 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 410, height: 898))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// The first call models Vision staying inside a synchronous request past the
/// describer's deadline. Later calls return immediately once admitted.
private final class BlockingTextRecognizer: TextRecognizing, @unchecked Sendable {
    let releaseFirst = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedCallCount = 0

    var callCount: Int { lock.withLock { storedCallCount } }

    func recognizeText(
        in image: CGImage, windowSize: CGSize, contentBounds: CGRect
    ) throws -> [RawTextElement] {
        let currentCall = lock.withLock { () -> Int in
            storedCallCount += 1
            return storedCallCount
        }
        if currentCall == 1 {
            _ = releaseFirst.wait(timeout: .now() + .seconds(10))
            firstFinished.signal()
        }
        return [RawTextElement(
            text: "Recovered", tapX: 100, textTopY: 100,
            textBottomY: 120, bboxWidth: 100, confidence: 0.99)]
    }
}
