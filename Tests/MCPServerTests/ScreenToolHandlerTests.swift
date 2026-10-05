// Copyright 2026 jfarcand@apache.org
// Licensed under the Apache License, Version 2.0
//
// ABOUTME: Tests for screen tool MCP handlers: screenshot, describe_screen, start/stop recording.
// ABOUTME: Verifies app-not-running checks, capture failure paths, and success responses.

import Foundation
import XCTest
@testable import HelperLib
@testable import mirroir_mcp

final class ScreenToolHandlerTests: XCTestCase {

    private var server: MCPServer!
    private var bridge: StubBridge!
    private var input: StubInput!
    private var capture: StubCapture!
    private var recorder: StubRecorder!
    private var describer: StubDescriber!

    override func setUp() {
        super.setUp()
        let policy = PermissionPolicy(skipPermissions: true, config: nil)
        server = MCPServer(policy: policy)
        bridge = StubBridge()
        input = StubInput()
        capture = StubCapture()
        recorder = StubRecorder()
        describer = StubDescriber()
        let registry = makeTestRegistry(
            bridge: bridge, input: input,
            capture: capture, recorder: recorder, describer: describer
        )
        MirroirMCP.registerScreenTools(
            server: server, registry: registry
        )
    }

    private func callTool(_ name: String, args: [String: JSONValue] = [:]) -> JSONRPCResponse {
        let request = JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": .object(args),
            ])
        )
        return server.handleRequest(request)!
    }

    private func extractText(_ response: JSONRPCResponse) -> String? {
        guard case .object(let result) = response.result,
              case .array(let content) = result["content"],
              case .object(let textObj) = content.first,
              case .string(let text) = textObj["text"] else { return nil }
        return text
    }

    private func isError(_ response: JSONRPCResponse) -> Bool {
        guard case .object(let result) = response.result,
              case .bool(let isErr) = result["isError"] else { return false }
        return isErr
    }

    private func contentBlockCount(_ response: JSONRPCResponse) -> Int {
        guard case .object(let result) = response.result,
              case .array(let content) = result["content"] else { return 0 }
        return content.count
    }

    // MARK: - screenshot

    func testScreenshotAppNotRunning() {
        bridge.processRunning = false
        let response = callTool("screenshot")
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("not running") ?? false)
    }

    func testScreenshotCaptureFails() {
        bridge.processRunning = true
        capture.captureResult = nil
        let response = callTool("screenshot")
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Failed to capture") ?? false)
    }

    func testScreenshotSuccess() {
        bridge.processRunning = true
        capture.captureResult = "iVBORw0KGgo=" // minimal base64 PNG prefix
        let response = callTool("screenshot")
        XCTAssertFalse(isError(response))

        // Verify an image content block is returned
        guard case .object(let result) = response.result,
              case .array(let content) = result["content"],
              case .object(let imgObj) = content.first else {
            return XCTFail("Expected image content")
        }
        XCTAssertEqual(imgObj["type"], .string("image"))
        XCTAssertEqual(imgObj["data"], .string("iVBORw0KGgo="))
    }

    func testScreenshotSettleMillisecondsBoundsAndConversion() {
        let defaultUs: UInt32 = 1_500_000
        XCTAssertEqual(MirroirMCP.screenshotSettleTimeoutUs(nil, defaultUs: defaultUs), defaultUs)
        XCTAssertEqual(MirroirMCP.screenshotSettleTimeoutUs(nil, defaultUs: .max), 5_000_000)
        XCTAssertEqual(MirroirMCP.screenshotSettleTimeoutUs(.number(0), defaultUs: defaultUs), 0)
        XCTAssertEqual(MirroirMCP.screenshotSettleTimeoutUs(.number(1), defaultUs: defaultUs), 1_000)
        XCTAssertEqual(
            MirroirMCP.screenshotSettleTimeoutUs(.number(5_000), defaultUs: defaultUs),
            5_000_000)
    }

    func testScreenshotRejectsInvalidSettleMillisecondsBeforeProcessLookup() {
        bridge.processRunning = false
        let invalidValues: [JSONValue] = [
            .number(-1), .number(5_001), .number(Double.greatestFiniteMagnitude),
            .number(1.5), .string("100"), .bool(true),
        ]
        for value in invalidValues {
            let response = callTool("screenshot", args: ["settle_ms": value])
            XCTAssertTrue(isError(response))
            XCTAssertEqual(
                extractText(response),
                "settle_ms must be an integer from 0 to 5000 milliseconds")
        }
    }

    func testScreenshotZeroSettleReturnsFirstFrame() {
        bridge.processRunning = true
        capture.captureResult = "iVBORw0KGgo="
        let response = callTool("screenshot", args: ["settle_ms": .number(0)])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(contentBlockCount(response), 1)
    }

    // MARK: - describe_screen

    func testDescribeScreenAppNotRunning() {
        bridge.processRunning = false
        let response = callTool("describe_screen")
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("not running") ?? false)
    }

    func testDescribeScreenDescriberFails() {
        bridge.processRunning = true
        describer.describeResult = nil
        let response = callTool("describe_screen")
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Failed to capture") ?? false)
    }

    func testDescribeScreenReturnsElements() {
        bridge.processRunning = true
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [
                TapPoint(text: "Settings", tapX: 100, tapY: 200, confidence: 0.95)
            ],
            screenshotBase64: "iVBORw0KGgo="
        )
        let response = callTool("describe_screen")
        XCTAssertFalse(isError(response))

        // Verify response contains element text
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Settings") ?? false)
        XCTAssertTrue(text?.contains("(100, 200)") ?? false)
    }

    func testDescribeScreenIncludesImageByDefault() {
        bridge.processRunning = true
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Hello", tapX: 10, tapY: 20, confidence: 0.9)],
            screenshotBase64: "iVBORw0KGgo="
        )
        let response = callTool("describe_screen")
        XCTAssertFalse(isError(response))
        XCTAssertEqual(contentBlockCount(response), 2, "Default response should have text + image")
    }

    func testDescribeScreenOmitsImageWhenParameterTrue() {
        bridge.processRunning = true
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Hello", tapX: 10, tapY: 20, confidence: 0.9)],
            screenshotBase64: "iVBORw0KGgo="
        )
        let response = callTool("describe_screen", args: ["omit_screenshot": .bool(true)])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(contentBlockCount(response), 1, "Should have text only when omit_screenshot=true")
        XCTAssertNotNil(extractText(response))
    }

    func testDescribeScreenOmitParameterOverridesEnvVar() {
        bridge.processRunning = true
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "Hello", tapX: 10, tapY: 20, confidence: 0.9)],
            screenshotBase64: "iVBORw0KGgo="
        )
        // Even if env var would omit, explicit false should include
        let response = callTool("describe_screen", args: ["omit_screenshot": .bool(false)])
        XCTAssertFalse(isError(response))
        XCTAssertEqual(contentBlockCount(response), 2, "Explicit false should include image regardless of env var")
    }

    // MARK: - start_recording

    func testStartRecordingSuccess() {
        recorder.startResult = nil
        let response = callTool("start_recording")
        XCTAssertFalse(isError(response))
        XCTAssertEqual(extractText(response), "Recording started")
    }

    func testStartRecordingError() {
        recorder.startResult = "Permission denied"
        let response = callTool("start_recording")
        XCTAssertTrue(isError(response))
        XCTAssertEqual(extractText(response), "Permission denied")
    }

    // MARK: - stop_recording

    func testStopRecordingSuccess() {
        recorder.stopResult = ("/tmp/recording.mov", nil)
        let response = callTool("stop_recording")
        XCTAssertFalse(isError(response))
        XCTAssertEqual(extractText(response), "Recording saved to: /tmp/recording.mov")
    }

    func testStopRecordingError() {
        recorder.stopResult = (nil, "No recording in progress")
        let response = callTool("stop_recording")
        XCTAssertTrue(isError(response))
        XCTAssertEqual(extractText(response), "No recording in progress")
    }

    func testStopRecordingNoFile() {
        recorder.stopResult = (nil, nil)
        let response = callTool("stop_recording")
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("no file") ?? false)
    }

    // MARK: - describe_screen scroll parameter

    func testDescribeScreenScrollDescriberFailsReturnsError() {
        bridge.processRunning = true
        describer.describeResult = nil
        let response = callTool("describe_screen", args: ["scroll": .bool(true)])
        XCTAssertTrue(isError(response))
        let text = extractText(response)
        XCTAssertTrue(text?.contains("Failed to capture") ?? false)
    }

    func testScrollInitialOCRTimeoutReturnsScreenshotWithoutSwiping() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [], screenshotBase64: "aW1hZ2Ux",
            ocrFailure: "OCR timed out before the deadline")

        let response = callTool("describe_screen", args: [
            "scroll": .bool(true), "omit_screenshot": .bool(true),
        ])

        XCTAssertTrue(isError(response))
        XCTAssertTrue(extractText(response)?.contains("INCOMPLETE FULL-PAGE SCAN") == true)
        XCTAssertTrue(extractText(response)?.contains("Initial OCR failed") == true)
        XCTAssertFalse(extractText(response)?.contains("(no text detected)") == true)
        XCTAssertEqual(contentBlockCount(response), 2,
                       "an OCR failure must include the captured image even when omission was requested")
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }

    func testScrollLaterOCRFailureReportsPartialElementsAndStops() {
        describer.describeResults = [
            ScreenDescriber.DescribeResult(
                elements: [TapPoint(text: "First", tapX: 100, tapY: 200, confidence: 0.9)],
                screenshotBase64: "aW1hZ2Ux"),
            ScreenDescriber.DescribeResult(
                elements: [], screenshotBase64: "aW1hZ2Uy",
                ocrFailure: "OCR busy: previous request still running"),
        ]

        let response = callTool("describe_screen", args: ["scroll": .bool(true)])

        XCTAssertTrue(isError(response))
        XCTAssertTrue(extractText(response)?.contains("First") == true)
        XCTAssertTrue(extractText(response)?.contains("OCR failed after scroll 1") == true)
        XCTAssertEqual(input.swipeCalls.count, 1)
        XCTAssertEqual(contentBlockCount(response), 2)
    }

    func testFullPageBudgetDeclinesAnotherSwipeBeforeWorstCaseOCR() {
        describer.describeResult = ScreenDescriber.DescribeResult(
            elements: [TapPoint(text: "First", tapX: 100, tapY: 200, confidence: 0.9)],
            screenshotBase64: "aW1hZ2Ux")

        let result = CalibrationScroller.collectFullPage(
            describer: describer, input: input, bridge: bridge,
            deadline: .now() + .seconds(19))

        XCTAssertTrue(result?.incompleteReason?.contains("time budget") == true)
        XCTAssertEqual(result?.elements.first?.text, "First")
        XCTAssertEqual(result?.scrollCount, 0)
        XCTAssertTrue(input.swipeCalls.isEmpty)
    }
}
